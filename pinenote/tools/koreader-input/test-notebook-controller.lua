--[[--
Host harness for the notebook's session controller (notebook.koplugin
nb_controller.lua).

The controller is pure, so this runs it under the koreader-bin bundle's
luajit with the real nb_input, nb_brush, nb_journal, nb_panel and
nb_geom underneath: scripted w9013 Stylus reports and cyttsp5 frames
(built in kernel event order, the touch side through a model of the
input core's slot and axis suppression) go in, and the commands that
come back are compared as one canonical token per command.

A Session wrapper plays the glue: it keeps the appended lines per page,
answers load_page with J.replay, and paints ink and render_page into a
simulated page buffer.  Around every call it checks the contract's
invariants, so every scripted case and the capture replays hold them:

  * every call returns a new array, never nb_input's shared NONE;
  * no ink or publish_ink while the plane is not armed (arm precedes
    the first ink), and none, nor any arm or append, after io_error;
  * no fsync from a call that leaves the pen in range (close and
    suspend excepted: the contract fsyncs there);
  * a render_page limited to a region changes nothing outside it (the
    region-limited rebuild equals a full one).

The Session also plays the glue's side of a failed write (fail_op): the
rest of the list runs less its append, arm, ink and publish_ink, then
io_error(err, failed_cmd) is called, so a failed append can be checked
against the page file it never reached.

Then the scripted properties: arm timing, io_error, fsync timing, page
turns blocked under a down pen (and a load that lands under one), undo
and redo by swipe and by button, the stroke eraser, rubber and tip
eraser records, the panel flows, swipe directions in all four
rotations, palm vetoes, suspend and resume, SYN_DROPPED, the action-id
guard, stale and failed loads, close, prefs cleaning, and the log line.
Then the rules against each other: a tool switch mid-stroke (with and
without a load pending), strokes and erases under a pending load, undo
across a turn, ink going dead, io_error and SYN_DROPPED mid stroke-erase,
resync into range, a controller reused after close, suspend and rotation
with the panel open, rotation mid-drag, a flick at exactly the
threshold, three fingers on the panel, activity rate limits, the action
guard's exact boundary, the eraser's reach at its edge, fsync page order,
and each kind of failed write.  Live ink is checked against Brush.render
of the replayed record, span for span, and every session's buffer
against a render of its replay.

Last, the operator's 2026-09-26 Stylus captures (pen-1.bin, pen-3.bin;
gitignored, so absent in CI, where that part SKIPs with one fixed PASS
line) go through the controller: one record per BTN_TOUCH:1, rubber
strokes recorded as eraser records, every line decodes, and the
buffer the live ink built is the replay's.  The per-event cost goes to
stderr, which the determinism check does not compare.

Usage: luajit test-notebook-controller.lua <koreader_dir> <plugin_dir> [capture_dir]
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")
local script_dir = arg[0]:match("^(.*)/[^/]*$") or "."
local capture_dir = arg[3] or (script_dir .. "/../pen/build/captures-20260926")
local _ = koreader_dir -- the controller is pure: the bundle supplies only luajit

package.path = plugin_dir .. "/?.lua;" .. package.path

local format, concat = string.format, table.concat
local floor = math.floor

local fail = 0
local function report(ok, label, msg)
    if msg and msg ~= "" then
        print(format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    else
        print(format("%s: %s", ok and "PASS" or "FAIL", label))
    end
    if not ok then fail = fail + 1 end
end

-- Purity: the controller may pull in the notebook's own modules only.
local before = {}
for k in pairs(package.loaded) do before[k] = true end
local Ctl = require("nb_controller")
local extra = {}
for k in pairs(package.loaded) do
    if not before[k] and not k:match("^nb_") then extra[#extra + 1] = k end
end
table.sort(extra)
report(#extra == 0, "nb_controller loads only notebook modules",
       concat(extra, ","))

local ffi = require("ffi")
local Brush = require("nb_brush")
local G = require("nb_geom")
local Input = require("nb_input")
local J = require("nb_journal")
local Panel = require("nb_panel")
local base_cfg = dofile(plugin_dir .. "/nb_config.lua")

local W, H = base_cfg.W, base_cfg.H
local XMAX, YMAX = base_cfg.abs_x_max, base_cfg.abs_y_max
local ID = "20260926T120000Z-00c0de"
local NB = { id = ID, title = "Test" }

-- Realtime microseconds.
local T0 = 1758844800 * 1000000
local function ms(n) return T0 + n * 1000 end
local NOW = T0
local function now() return NOW end

-- Physical px to the digitizer unit that lands on it.
local function RX(px) return floor(px * XMAX / (W - 1) + 0.5) end
local function RY(py) return floor(py * YMAX / (H - 1) + 0.5) end

------------------------------------------------------------------------
-- Event builders
------------------------------------------------------------------------

local CODE = {
    PEN = { 1, 320 }, RUBBER = { 1, 321 }, TOUCH = { 1, 330 },
    X = { 3, 0 }, Y = { 3, 1 }, P = { 3, 24 }, D = { 3, 25 },
    SLOT = { 3, 47 }, MX = { 3, 53 }, MY = { 3, 54 }, ID = { 3, 57 },
}

local function append_all(dst, src)
    for i = 1, #src do dst[#dst + 1] = src[i] end
    return dst
end

local function steps(...)
    local out = {}
    for _, list in ipairs({ ... }) do append_all(out, list) end
    return out
end

-- list[i..j] (j defaults to the end), to split a gesture around an
-- interleaved event.
local function slice(list, i, j)
    local out = {}
    for k = i, j or #list do out[#out + 1] = list[k] end
    return out
end

-- One report: the listed events, then SYN_REPORT.  Pen X/Y carry the
-- digitizer unit as raw and device.lua's rounded px as value.
local function frame(src, t, list)
    local out = {}
    for i = 1, #list, 2 do
        local name, v = list[i], list[i + 1]
        local tc = CODE[name]
        local ev = { src = src, t = t, type = tc[1], code = tc[2], value = v }
        if src == "pen" and (name == "X" or name == "Y") then
            local n, max = W, XMAX
            if name == "Y" then n, max = H, YMAX end
            ev.raw = v
            ev.value = floor(v * n / max + 0.5)
        end
        out[#out + 1] = ev
    end
    out[#out + 1] = { src = src, t = t, type = 0, code = 0, value = 0 }
    return out
end

local function pen(t_ms, ...) return frame("pen", ms(t_ms), { ... }) end
local function pen_drop(t_ms)
    return { { src = "pen", t = ms(t_ms), type = 0, code = 3, value = 0 } }
end

local function key_of(tool) return tool == "rubber" and "RUBBER" or "PEN" end

local function hover_in(t_ms, tool, px, py)
    return pen(t_ms, key_of(tool), 1, "X", RX(px), "Y", RY(py), "D", 20)
end
-- The report that takes the pen out of range; the leave waits for it.
local function prox_out(t_ms, tool) return pen(t_ms, key_of(tool), 0) end
-- Out of range for good: the report, then the leave's timer, run a
-- millisecond after prox_leave_us to cover the handling latency.
local LEAVE_MS = base_cfg.prox_leave_us / 1000 + 1
local function hover_out(t_ms, tool)
    local evs = prox_out(t_ms, tool)
    evs[#evs + 1] = { timer = ms(t_ms + LEAVE_MS) }
    return evs
end

-- A pen-down through physical points, 3 ms apart, then the lift report.
-- Returns the events and the lift's time.
local function down(t_ms, pts, p)
    local evs = pen(t_ms, "TOUCH", 1, "P", p or 2000,
                    "X", RX(pts[1][1]), "Y", RY(pts[1][2]))
    for i = 2, #pts do
        append_all(evs, pen(t_ms + 3 * (i - 1), "X", RX(pts[i][1]),
                            "Y", RY(pts[i][2])))
    end
    local t_up = t_ms + 3 * #pts
    append_all(evs, pen(t_up, "TOUCH", 0, "P", 0))
    return evs, t_up
end

-- A whole visit: in range, one pen-down, out of range.
local function visit(t_ms, tool, pts, p)
    local evs, t_up = down(t_ms + 5, pts, p)
    return steps(hover_in(t_ms, tool, pts[1][1], pts[1][2]), evs,
                 hover_out(t_up + 5, tool)), t_up + 5
end

-- A cyttsp5 as the input core presents it: ABS_MT_SLOT only when the slot
-- changes, an axis only when its value changes.  acts: { {slot, id=,
-- x=, y=} } in record order, lifts last.
local function kernel()
    local K = { slot = 0, x = {}, y = {} }
    function K.frame(t_ms, acts)
        local list = {}
        for _, a in ipairs(acts) do
            local s = a[1]
            local evs = {}
            if a.id then
                evs[#evs + 1] = "ID"
                evs[#evs + 1] = a.id
            end
            if a.x and a.x ~= K.x[s] then
                K.x[s] = a.x
                evs[#evs + 1] = "MX"
                evs[#evs + 1] = a.x
            end
            if a.y and a.y ~= K.y[s] then
                K.y[s] = a.y
                evs[#evs + 1] = "MY"
                evs[#evs + 1] = a.y
            end
            if #evs > 0 then
                if s ~= K.slot then
                    K.slot = s
                    list[#list + 1] = "SLOT"
                    list[#list + 1] = s
                end
                for i = 1, #evs do list[#list + 1] = evs[i] end
            end
        end
        return frame("touch", ms(t_ms), list)
    end
    return K
end

local next_tid = 100
local function tid()
    next_tid = next_tid + 1
    return next_tid
end

local function lerp(a, b, u) return floor(a + (b - a) * u + 0.5) end

-- One finger from (x0, y0) to (x1, y1) in n moves dt ms apart, then up.
local function finger(K, t_ms, x0, y0, x1, y1, n, dt)
    local evs = K.frame(t_ms, { { 0, id = tid(), x = x0, y = y0 } })
    for i = 1, n do
        append_all(evs, K.frame(t_ms + i * dt,
            { { 0, x = lerp(x0, x1, i / n), y = lerp(y0, y1, i / n) } }))
    end
    append_all(evs, K.frame(t_ms + (n + 1) * dt, { { 0, id = -1 } }))
    return evs
end

local function tap_at(K, t_ms, x, y) return finger(K, t_ms, x, y, x, y, 0, 60) end

-- Three fingers landing together at starts, moving by (dx, dy).
local function three(K, t_ms, starts, dx, dy, n, dt)
    local acts = {}
    for i, p in ipairs(starts) do
        acts[i] = { i - 1, id = tid(), x = p[1], y = p[2] }
    end
    local evs = K.frame(t_ms, acts)
    for s = 1, n do
        local mv = {}
        for i, p in ipairs(starts) do
            mv[i] = { i - 1, x = lerp(p[1], p[1] + dx, s / n),
                      y = lerp(p[2], p[2] + dy, s / n) }
        end
        append_all(evs, K.frame(t_ms + s * dt, mv))
    end
    local up = {}
    for i = 1, #starts do up[i] = { i - 1, id = -1 } end
    append_all(evs, K.frame(t_ms + (n + 1) * dt, up))
    return evs
end

------------------------------------------------------------------------
-- Canonical command tokens
------------------------------------------------------------------------

local function num(v)
    if v == floor(v) then return format("%d", v) end
    return format("%.3f", v)
end

local function rect(r)
    return format("%d,%d,%d,%d", r.x, r.y, r.w, r.h)
end

local function fmt(cmd)
    local op = cmd.op
    if op == "arm" then
        local rs = {}
        for i, r in ipairs(cmd.rects) do
            rs[i] = rect(r) .. format("/0x%02x", r.hint)
        end
        return "arm(" .. concat(rs, ";") .. ")"
    elseif op == "disarm" then
        return "disarm"
    elseif op == "ink" then
        return format("ink(%s/%s%s)", cmd.comp, cmd.pat,
                      cmd.dens and ("/" .. num(cmd.dens)) or "")
    elseif op == "publish_ink" then
        return "publish"
    elseif op == "append" then
        local rec = J.decode(cmd.line)
        if not rec then return "append(p" .. num(cmd.page) .. " BAD)" end
        local s = "append(p" .. num(cmd.page) .. " " .. rec.k .. num(rec.a)
        if rec.k == "x" then
            local ids = {}
            for i, v in ipairs(rec.ids) do ids[i] = num(v) end
            s = s .. "[" .. concat(ids, ",") .. "]"
        elseif rec.k == "s" then
            s = s .. " " .. rec.tool .. (rec.gap == 1 and " gap" or "")
        end
        return s .. ")"
    elseif op == "fsync" then
        return "fsync(p" .. num(cmd.page) .. ")"
    elseif op == "load_page" then
        return "load(p" .. num(cmd.page) .. ")"
    elseif op == "render_page" then
        return format("render(p%s %d%s)", num(cmd.page), #cmd.strokes,
                      cmd.region and (" " .. rect(cmd.region)) or "")
    elseif op == "repaint" then
        return cmd.region and ("repaint(" .. rect(cmd.region) .. ")") or "repaint"
    elseif op == "panel" then
        return cmd.layout and format("panel(%d,%d)", cmd.layout.x, cmd.layout.y)
               or "panel(hide)"
    elseif op == "washer_charge" then
        return "washer"
    elseif op == "activity" then
        return "activity"
    elseif op == "schedule" then
        return "schedule(" .. num(cmd.delay_us) .. ")"
    elseif op == "resync_pen" then
        return "resync_pen"
    elseif op == "touch_down_changed" then
        return cmd.any_down and "touch(down)" or "touch(up)"
    elseif op == "rotation_hold" then
        return cmd.on and "hold(on)" or "hold(off)"
    elseif op == "save_prefs" then
        local p = cmd.prefs
        -- "-": not chosen, so the default applies.
        local s = format("prefs(%s,%s,%s,%s", p.brush or "-", p.size or "-",
                         p.mode or "-", p.rubber or "-")
        if p.last_id then s = s .. (p.last_id == ID and " last" or " last=other") end
        if p.last_page and p.last_id and p.last_page[p.last_id] then
            s = s .. " p=" .. num(p.last_page[p.last_id])
        end
        return s .. ")"
    elseif op == "log" or op == "toast" or op == "new_notebook"
           or op == "open_list" or op == "close_notebook" then
        return op
    end
    return "UNKNOWN(" .. tostring(op) .. ")"
end

-- Tokens that recur in expectations: the canvas arm, and one report's
-- solid black or white ink with its publish.
local ARM = "arm(0,0,1872,1404/0x00)"
local INK = "ink(black/solid) publish"
local WHITE = "ink(white/solid) publish"
local function j(...) return concat({ ... }, " ") end

local QUIET = { activity = true, touch_down_changed = true, schedule = true }
local SHOW_TIMER = { activity = true, touch_down_changed = true }

local function seq(cmds, drop)
    drop = drop or QUIET
    local t = {}
    for _, c in ipairs(cmds) do
        if not drop[c.op] then t[#t + 1] = fmt(c) end
    end
    return concat(t, " ")
end

local function expect(label, cmds, want, drop)
    local got = seq(cmds, drop)
    if got == want then
        report(true, label)
    else
        report(false, label, "\n  got:  " .. got .. "\n  want: " .. want)
    end
end

local function ops(cmds, op)
    local out = {}
    for _, c in ipairs(cmds) do
        if c.op == op then out[#out + 1] = c end
    end
    return out
end

------------------------------------------------------------------------
-- The simulated page buffer: black pixels keyed y * W + x
------------------------------------------------------------------------

local function painter(px, comp, pat, clip)
    local mstyle = { pat = pat }
    return function(y, x0, x1, dens)
        if clip then
            if y < clip.y or y >= clip.y + clip.h then return end
            if x0 < clip.x then x0 = clip.x end
            if x1 > clip.x + clip.w - 1 then x1 = clip.x + clip.w - 1 end
        end
        local base = y * W
        for x = x0, x1 do
            if comp == "white" then
                px[base + x] = nil
            elseif comp == "black" or Brush.mask(mstyle, dens, x, y) then
                px[base + x] = true
            end
        end
    end
end

local function paint_strokes(px, strokes, clip)
    for _, e in ipairs(strokes) do
        Brush.render(e.style, e.points, W, H,
                     painter(px, e.style.comp, e.style.pat, clip))
    end
end

local function differ(a, b)
    local n = 0
    for k in pairs(a) do if not b[k] then n = n + 1 end end
    for k in pairs(b) do if not a[k] then n = n + 1 end end
    return n
end

------------------------------------------------------------------------
-- Session: the controller plus a glue stand-in and the invariants
------------------------------------------------------------------------

local Session = {}
Session.__index = Session

local function new_session(o)
    o = o or {}
    local S = setmetatable({}, Session)
    S.cfg = o.cfg or base_cfg
    S.lat = o.lat or 500
    S.c = Ctl.new{ cfg = S.cfg, prefs = o.prefs or {}, now_rt_us = now,
                   rotation_mode = o.mode or 0 }
    S.K = kernel()
    S.lines = {}
    S.px = {}
    S.shown = nil
    S.layout = nil
    S.armed, S.failed = false, false
    S.violations = {}
    S.appends, S.logs, S.log_lines, S.washers = 0, 0, {}, 0
    S.skipped = 0
    return S
end

function Session:violate(what)
    if #self.violations < 5 then self.violations[#self.violations + 1] = what end
    self.nviol = (self.nviol or 0) + 1
end

function Session:_track(cmd)
    local op = cmd.op
    if op == "arm" then
        if self.failed then self:violate("arm after io_error") end
        self.armed = true
    elseif op == "disarm" then
        self.armed = false
    elseif op == "ink" or op == "publish_ink" then
        if not self.armed then self:violate(op .. " while not armed") end
        if self.failed then self:violate(op .. " after io_error") end
        if op == "ink" then
            local sp = cmd.spans
            local paint = painter(self.px, cmd.comp, cmd.pat)
            for i = 1, #sp, 3 do paint(sp[i], sp[i + 1], sp[i + 2], cmd.dens) end
        end
    elseif op == "append" then
        if self.failed then self:violate("append after io_error") end
        if not J.decode(cmd.line) then self:violate("undecodable append") end
        local l = self.lines[cmd.page] or {}
        l[#l + 1] = cmd.line
        self.lines[cmd.page] = l
        self.appends = self.appends + 1
    elseif op == "render_page" then
        if cmd.region then
            local R = cmd.region
            for key in pairs(self.px) do
                local y, x = floor(key / W), key % W
                if x >= R.x and x < R.x + R.w and y >= R.y and y < R.y + R.h then
                    self.px[key] = nil
                end
            end
            paint_strokes(self.px, cmd.strokes, R)
            local full = {}
            paint_strokes(full, cmd.strokes)
            if differ(full, self.px) ~= 0 then
                self:violate("render_page region misses a change")
            end
        else
            self.px = {}
            paint_strokes(self.px, cmd.strokes)
        end
        self.shown = cmd.page
    elseif op == "panel" then
        self.layout = cmd.layout
    elseif op == "log" then
        self.logs = self.logs + 1
        self.log_lines[#self.log_lines + 1] = cmd.line
    elseif op == "washer_charge" then
        self.washers = self.washers + 1
    end
end

-- What the glue skips in a list after its first failed write.
local SKIP_AFTER_ERROR = { append = true, arm = true, ink = true, publish_ink = true }

-- Any controller method, with the invariants checked on what it returns.
-- Set fail_op ("append" or "fsync") to make the next such command fail:
-- as the glue does, the rest of the list runs less its writes and ink,
-- then io_error(err, cmd) is called.  Returns the commands as run, the
-- failed one included, then io_error's.
function Session:run(name, ...)
    local c = self.c
    if name == "open" then self.armed = false end -- the glue resets the owner
    local out = c[name](c, ...)
    if type(out) ~= "table" or out == self.last_out or out == Input.NONE
       or getmetatable(out) ~= nil then
        self:violate(name .. " returned a reused or foreign array")
    end
    self.last_out = out
    local has_fsync, err, err_cmd = false, nil, nil
    local ran = {}
    for _, cmd in ipairs(out) do
        if err and SKIP_AFTER_ERROR[cmd.op] then
            self.skipped = self.skipped + 1
        else
            ran[#ran + 1] = cmd
            if not err and cmd.op == self.fail_op then
                -- Nothing of this write reaches the page file.
                self.fail_op = nil
                err, err_cmd = "ENOSPC /data/notebooks/" .. ID, cmd
            else
                self:_track(cmd)
                if cmd.op == "fsync" then has_fsync = true end
            end
        end
    end
    if has_fsync and name ~= "close" and name ~= "suspend" and c:pen_in_range() then
        self:violate("fsync from " .. name .. " with the pen in range")
    end
    if name == "io_error" then self.failed = true end
    if err then append_all(ran, self:run("io_error", err, err_cmd)) end
    return ran
end

-- Intents straight into the dispatcher (orders nb_input cannot produce,
-- such as a swipe under a hovering pen), tracked like any call.
function Session:inject(intents)
    local out = {}
    self.c:_run(intents, out)
    for _, cmd in ipairs(out) do
        self:_track(cmd)
        if cmd.op == "fsync" and self.c:pen_in_range() then
            self:violate("fsync from injected intents with the pen in range")
        end
    end
    return out
end

function Session:open(n, page)
    n = n or 0
    return self:run("open", NB, n, page or J.replay(self.lines[n] or {}, self.cfg))
end

-- Feed events and timers ({timer=us}).  NOW follows each event by the
-- session's latency, or stays at held_now (ev_at).
function Session:_feed(list, held_now)
    local acc = {}
    for _, e in ipairs(list) do
        local out
        if e.timer then
            NOW = e.timer
            out = self:run("on_timer", e.timer)
        else
            NOW = held_now or (e.t + self.lat)
            out = self:run("feed", e)
        end
        append_all(acc, out)
    end
    return acc
end

function Session:ev(list) return self:_feed(list) end
function Session:ev_at(list, held_now) return self:_feed(list, held_now) end

function Session:loaded(n)
    return self:run("page_loaded", n, J.replay(self.lines[n] or {}, self.cfg))
end

-- The replay of a page as the glue would read it back.
function Session:replay(n)
    return J.replay(self.lines[n] or {}, self.cfg)
end

function Session:check(label)
    report((self.nviol or 0) == 0, label .. ": invariants held",
           self.nviol and (num(self.nviol) .. " violations: "
                           .. concat(self.violations, "; ")) or "")
    local page = self:replay(self.shown or 0)
    local full = {}
    paint_strokes(full, page.strokes)
    local d, black = differ(full, self.px), 0
    for _ in pairs(full) do black = black + 1 end
    report(d == 0, label .. ": the page buffer is the render of its replay",
           format("%d strokes, %d black px, %d differ", #page.strokes, black, d))
end

-- A button's centre, physical, from the layout the glue last got.
function Session:button(id)
    local L = assert(self.layout, "no panel shown")
    for _, it in ipairs(L.items) do
        if it.id == id then
            local r = self.c.r
            return G.to_physical(r, W, H, floor(it.x + it.w / 2),
                                 floor(it.y + it.h / 2))
        end
    end
    error("no item " .. id)
end

function Session:tap_button(id, t_ms)
    local x, y = self:button(id)
    return self:ev(tap_at(self.K, t_ms, x, y))
end

-- A long press at physical (x, y): landing, the timer, the lift.
function Session:long_press(t_ms, x, y)
    local acc = self:ev(self.K.frame(t_ms, { { 0, id = tid(), x = x, y = y } }))
    append_all(acc, self:ev({ { timer = ms(t_ms + base_cfg.longpress_us / 1000) } }))
    append_all(acc, self:ev(self.K.frame(t_ms + 900, { { 0, id = -1 } })))
    return acc
end

-- A default session, open on a blank page 0 with ink live.
local function live_session(o)
    local S = new_session(o)
    S:open(0)
    S:run("set_ink_live", true)
    return S
end

local function decode_last(S, n)
    local l = S.lines[n or 0]
    return l and J.decode(l[#l])
end

-- A stroke's recorded box, clipped to the panel: the region an undo,
-- redo or stroke erase of it may change.
local function region_of(bb)
    local x0, y0 = math.max(0, bb[1]), math.max(0, bb[2])
    local x1, y1 = math.min(W - 1, bb[3]), math.min(H - 1, bb[4])
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- Three fingers on the right or the left half, for undo and redo.
local LEFT3 = { { 1400, 400 }, { 1400, 600 }, { 1400, 800 } }
local RIGHT3 = { { 400, 400 }, { 400, 600 }, { 400, 800 } }

------------------------------------------------------------------------
-- Cross-module pins
------------------------------------------------------------------------

do
    local pn = Panel.new(base_cfg)
    pn:open(900, 700, W, H)
    local ids = {}
    for _, it in ipairs(pn:layout({}).items) do
        local b = it.id:match("^brush:(.+)$")
        if b then ids[#ids + 1] = b end
    end
    report(concat(ids, ",") == concat(Brush.IDS, ","),
           "the panel's brush buttons are nb_brush's IDS, in order", concat(ids, ","))
end

do
    -- Brush.style -> stroke_record -> encode -> decode -> J.style is the
    -- identity, so a live stroke and its replay draw with one style.
    local fields = { "brush", "size", "tool", "rmin", "rmax", "gamma", "plo",
                     "phi", "comp", "pat", "dlo", "dhi" }
    local bad, n = {}, 0
    local tip_eraser = Brush.style("fine", "M", "eraser", base_cfg)
    tip_eraser.plo, tip_eraser.phi = base_cfg.pen_p_lo, base_cfg.pen_p_hi
    local styles = { tip_eraser }
    for _, b in ipairs(Brush.IDS) do
        for _, sz in ipairs({ "S", "M", "L" }) do
            for _, tool in ipairs({ "pen", "eraser" }) do
                styles[#styles + 1] = Brush.style(b, sz, tool, base_cfg)
            end
        end
    end
    for _, st in ipairs(styles) do
        n = n + 1
        local rec = J.decode(J.encode(J.stroke_record(1, st, 0, T0,
            { { t = T0, rawx = 100, rawy = 100, p = 500, tx = 0, ty = 0 } },
            false, { 0, 0, 1, 1 })))
        local back = J.style(rec)
        for _, f in ipairs(fields) do
            if back[f] ~= st[f] then
                bad[#bad + 1] = st.brush .. "/" .. st.size .. "/" .. st.tool .. "." .. f
            end
        end
    end
    report(#bad == 0, "every recorded style replays as itself",
           format("%d styles%s", n, #bad > 0 and (": " .. concat(bad, ",")) or ""))
end

------------------------------------------------------------------------
-- Open, and the first write
------------------------------------------------------------------------

do
    local S = new_session({ prefs = { brush = "ballpoint" } })
    expect("open: disarm, render the page and repaint; remember the notebook",
           S:open(0), "disarm render(p0 0) repaint prefs(ballpoint,-,-,- last)")
    expect("open: ink turning live with no pen in range arms nothing",
           S:run("set_ink_live", true), "")
    local got = S:ev(hover_in(0, "pen", 400, 300))
    expect("prox in with ink live: hold rotation, arm the canvas at 0x00",
           got, "hold(on) arm(0,0,1872,1404/0x00)")
    local pts = { { 400, 300 }, { 410, 302 }, { 420, 305 }, { 430, 310 } }
    local evs, t_up = down(10, pts, 2400)
    got = S:ev(evs)
    expect("a stroke: a dot, then a segment per report, each published; "
           .. "append and log at pen-up",
           got, j(INK, "activity", INK, INK, INK, "append(p0 s1 pen) log"), {})
    local spans = {}
    for _, c in ipairs(ops(got, "ink")) do append_all(spans, c.spans) end
    local rec = decode_last(S)
    local want = {}
    Brush.render(J.style(rec), J.points_px(rec, S.cfg), W, H,
                 function(y, x0, x1) want[#want + 1] = y; want[#want + 1] = x0
                                     want[#want + 1] = x1 end)
    report(concat(spans, ",") == concat(want, ","),
           "live ink is Brush.render of the replayed record, span for span",
           format("%d spans", #spans / 3))
    report(rec.tool == "pen" and rec.brush == "ballpoint" and rec.rot == 0
           and rec.t0 == ms(10) and rec.gap == 0 and #rec.d == 24,
           "the record: tool, brush, rotation mode, t0, gap, four samples")
    local x0, y0, x1, y1 = Brush.bbox(J.style(rec), J.points_px(rec, S.cfg))
    report(concat(rec.bb, ",") == concat({ x0, y0, x1, y1 }, ","),
           "the record's bb is Brush.bbox of its samples", concat(rec.bb, ","))
    got = S:ev(hover_out(t_up + 20, "pen"))
    expect("prox out: fsync the page written, release the hold", got,
           "fsync(p0) hold(off)")
    got = S:ev(steps(hover_in(t_up + 100, "pen", 600, 600), hover_out(t_up + 150, "pen")))
    expect("a hover with no ink: no arm (still armed), no fsync (nothing new)",
           got, "hold(on) hold(off)")
    S:check("first write")
end

------------------------------------------------------------------------
-- The pen-up log line
------------------------------------------------------------------------

do
    local S = live_session({ prefs = { brush = "ballpoint" } })
    S:ev(hover_in(0, "pen", 500, 500))
    -- Reports at 10, 13, 16 and 19 ms, handled at 10.5, 20, 20.1 and
    -- 20.2 ms: 16 and 19 were queued behind 13, a batch of three.
    local handled = { ms(10) + 500, ms(20), ms(20) + 100, ms(20) + 200 }
    local evs = { pen(10, "TOUCH", 1, "P", 2000, "X", RX(500), "Y", RY(500)),
                  pen(13, "X", RX(505)), pen(16, "X", RX(510)), pen(19, "X", RX(515)) }
    for i, e in ipairs(evs) do
        S:ev_at(e, handled[i])
        S:run("note_timing", "stamp", 100 + 50 * i)
        S:run("note_timing", "publish", 800 + 100 * i)
    end
    S:run("note_timing", "bogus", 7)
    S:ev_at(pen(22, "TOUCH", 0), ms(22) + 300)
    report(S.log_lines[1] == "pen-up page=0 rec=s1 tool=pen use=ink n=4 dur=9000us "
           .. "gap=0 hits=0 batch=3 lag=7000us drops=0 stamp=4/900/300us "
           .. "publish=4/4200/1200us append=- fsync=-",
           "log: samples, duration, batch run, lag, drops and timings", S.log_lines[1])
    S:run("note_timing", "append", 80)
    S:ev(hover_out(30, "pen"))
    S:run("note_timing", "fsync", 5000)
    S:ev(visit(100, "pen", { { 700, 700 } }))
    report(S.log_lines[2] == "pen-up page=0 rec=s2 tool=pen use=ink n=1 dur=0us "
           .. "gap=0 hits=0 batch=1 lag=500us drops=0 stamp=- publish=- "
           .. "append=1/80/80us fsync=1/5000/5000us",
           "log: timings noted since the previous line, the append and fsync included",
           S.log_lines[2])
    S:check("log line")
end

------------------------------------------------------------------------
-- Arming
------------------------------------------------------------------------

do
    local S = new_session()
    S:open(0)
    local got = S:ev(hover_in(0, "pen", 500, 500))
    expect("arm: prox in while ink is not live: hold only", got, "hold(on)")
    got = S:ev((down(10, { { 500, 500 }, { 520, 500 } })))
    expect("arm: a stroke while ink is not live draws and records nothing",
           got, "")
    got = S:run("set_ink_live", true)
    expect("arm: ink turning live with the pen in range arms at once", got,
           "arm(0,0,1872,1404/0x00)")
    got = S:ev((down(40, { { 500, 600 }, { 520, 600 } })))
    expect("arm: then ink needs no second arm", got,
           "ink(black/solid) publish ink(black/solid) publish append(p0 s1 pen) log")
    S:check("arm while not live")
end

do
    -- set_ink_live with a snapshot: the pen found in range by the snapshot.
    local S = new_session()
    S:open(0)
    NOW = ms(0)
    local got = S:run("set_ink_live", true, { prox = true, tool = "pen", touching = false })
    expect("arm: set_ink_live(true, snap) resyncs the pen, then arms", got,
           "hold(on) arm(0,0,1872,1404/0x00)")
    got = S:ev(pen(5, "X", RX(300), "Y", RY(300)))
    append_all(got, S:ev((down(10, { { 300, 300 } }))))
    expect("arm: a pen found by snapshot inks from its first real contact", got,
           "ink(black/solid) publish append(p0 s1 pen) log")
    S:check("arm by snapshot")
end

------------------------------------------------------------------------
-- The stroke eraser (and arming again after its render)
------------------------------------------------------------------------

local function three_lines(S, t_ms)
    -- A at y=200, B at y=700, C at y=1200, left to right.
    for i, y in ipairs({ 200, 700, 1200 }) do
        S:ev(visit(t_ms + (i - 1) * 100, "pen",
                   { { 300, y }, { 700, y }, { 1100, y }, { 1500, y } }))
    end
end

-- A session opened on page 0 as another session wrote it (a copy: the
-- writer's own replay must not see this session's appends).
local function session_on(lines, o)
    local S = new_session(o)
    S.lines[0] = slice(lines, 1)
    S:open(0)
    S:run("set_ink_live", true)
    return S
end

do
    local W1 = live_session({ prefs = { brush = "ballpoint" } })
    three_lines(W1, 0)
    local S = session_on(W1.lines[0], { prefs = { brush = "ballpoint",
                                                  mode = "stroke_erase" } })
    local before = S:replay(0).strokes
    local RB, RC = region_of(before[2].bb), region_of(before[3].bb)
    local got = S:ev(hover_in(1000, "pen", 900, 650))
    expect("stroke erase: prox in arms as for ink", got,
           "hold(on) arm(0,0,1872,1404/0x00)")
    local evs, t_up = down(1010, { { 900, 650 }, { 900, 690 }, { 900, 750 } })
    got = S:ev(evs)
    expect("stroke erase: B vanishes live when first touched; at pen-up an x record; "
           .. "the render waits for the pen to leave", got,
           "ink(white/solid) publish append(p0 x4[2]) log")
    local line = S.log_lines[#S.log_lines]
    report(line:match(" rec=x4 tool=pen use=strokes n=3 ")
           and line:match(" hits=1 ") ~= nil,
           "stroke erase: the log names the x record and its hits", line)
    -- Still in range, nothing armed since the render: the report that
    -- first draws arms, in the same call.
    local e2 = down(t_up + 20, { { 1400, 1150 }, { 1400, 1190 } })
    local first = S:ev(slice(e2, 1, 5))
    local rest = S:ev(slice(e2, 6))
    expect("stroke erase: a path that hits nothing at its first sample draws nothing",
           first, "")
    expect("stroke erase: the report that hits C whites it out, still armed", rest,
           j(WHITE, "append(p0 x5[3]) log"))
    got = S:ev((down(t_up + 100, { { 100, 1000 }, { 150, 1000 } })))
    expect("stroke erase: a path that hits nothing appends nothing, logs the pen-up",
           got, "log")
    local page = S:replay(0)
    report(#page.strokes == 1 and page.strokes[1].a == 1 and page.next_action == 6,
           "stroke erase: the replay keeps A only", format("%d strokes", #page.strokes))
    got = S:ev(hover_out(t_up + 200, "pen"))
    append_all(got, S:ev(three(S.K, t_up + 1000, LEFT3, -400, 0, 5, 20)))
    local RBC = { x = RB.x, y = RB.y, w = RC.x + RC.w - RB.x, h = RC.y + RC.h - RB.y }
    expect("stroke erase: the leave syncs, then renders B and C back as one region; "
           .. "undo brings C back", got,
           j("fsync(p0) disarm render(p0 1 " .. rect(RBC) .. ") repaint(" .. rect(RBC)
             .. ") hold(off) append(p0 u5) disarm",
             "render(p0 2 " .. rect(RC) .. ") repaint(" .. rect(RC) .. ") fsync(p0)"))
    S:check("stroke erase")
end

do
    -- With the panel open, the panel update a stroke erase makes (its
    -- record clears Redo) waits for the leave with the render: nothing
    -- page-scale or panel-sized is painted while the pen is in range.
    local W1 = live_session({ prefs = { brush = "ballpoint" } })
    three_lines(W1, 0)
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    local RB = rect(region_of(S:replay(0).strokes[2].bb))
    S:long_press(500, 1700, 1300)
    S:ev(three(S.K, 3000, LEFT3, -400, 0, 5, 20))
    report(S.c:_panel_state().can_redo, "stroke erase, panel open: an undo enables Redo")
    S:ev(hover_in(4000, "pen", 900, 650))
    local got = S:ev((down(4010, { { 900, 650 }, { 900, 700 }, { 900, 750 } })))
    expect("stroke erase, panel open: at pen-up only the record; render and panel wait",
           got, j(WHITE, "append(p0 x4[2]) log"))
    got = S:ev(hover_out(4100, "pen"))
    local L = S.layout
    expect("stroke erase, panel open: the leave syncs, renders, then updates the panel",
           got, j("fsync(p0) disarm render(p0 1 " .. RB .. ") repaint(" .. RB .. ")",
                  format("panel(%d,%d)", L.x, L.y), "hold(off)"))
    report(not S.c:_panel_state().can_redo, "stroke erase, panel open: Redo is off")
    S:check("stroke erase, panel open")
end

do
    -- Legs tested one report at a time pick exactly what Brush.hits finds
    -- along the whole path at pen-up.
    local W1 = live_session({ prefs = { brush = "brushpen" } })
    for i = 1, 6 do
        local y = 150 + 180 * i
        W1:ev(visit(100 * i, "pen", { { 200 + 40 * i, y }, { 900, y + 30 },
                                     { 1600 - 40 * i, y } }, 1500 + 300 * i))
    end
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    local path, pts = {}, {}
    for i = 0, 12 do
        path[i + 1] = { 500 + 60 * i, i % 2 == 0 and 250 or 900 }
        pts[i + 1] = { x = G.raw_to_px(RX(path[i + 1][1]), XMAX, W),
                       y = G.raw_to_px(RY(path[i + 1][2]), YMAX, H) }
    end
    S:ev(visit(2000, "pen", path))
    local rec = decode_last(S)
    local R = Brush.style(Brush.IDS[1], "M", "eraser", base_cfg).rmin
    local want = {}
    for _, e in ipairs(W1:replay(0).strokes) do
        if Brush.hits(pts, R, e.points, e.style, e.bb) then want[#want + 1] = e.a end
    end
    report(rec and rec.k == "x" and concat(rec.ids, ",") == concat(want, ",")
           and #want >= 2 and #want < 6,
           "stroke erase: a zigzag picks what Brush.hits finds along the whole path",
           "ids " .. (rec and rec.ids and concat(rec.ids, ",") or "-")
           .. " want " .. concat(want, ","))
    S:check("zigzag stroke erase")
end

do
    -- Area-eraser strokes are never picked; the rubber in stroke mode is
    -- a stroke eraser.
    local W1 = live_session({ prefs = { brush = "marker" } })
    W1:ev(visit(0, "pen", { { 400, 400 }, { 800, 400 } }))
    W1:ev(visit(100, "rubber", { { 600, 380 }, { 600, 420 } }, 500))
    local S = session_on(W1.lines[0], { prefs = { brush = "marker", rubber = "stroke" } })
    local page = S:replay(0)
    report(#page.strokes == 2 and page.strokes[2].rec.tool == "eraser",
           "stroke erase setup: an ink stroke with an area-erase stroke across it")
    local R = rect(region_of(page.strokes[1].bb))
    local got = S:ev(visit(1000, "rubber", { { 600, 300 }, { 600, 500 } }, 500))
    expect("the rubber in stroke mode removes the ink stroke, never the eraser stroke",
           got, j("hold(on)", ARM, WHITE, "append(p0 x3[1]) log fsync(p0) disarm",
                  "render(p0 1 " .. R .. ") repaint(" .. R .. ") hold(off)"))
    S:check("rubber stroke erase")
end

------------------------------------------------------------------------
-- Eraser records
------------------------------------------------------------------------

do
    local S = live_session()
    local got = S:ev((visit(0, "rubber", { { 500, 500 }, { 540, 500 } }, 700)))
    expect("rubber, area mode: inks white and records an eraser stroke", got,
           j("hold(on)", ARM, WHITE, WHITE, "append(p0 s1 eraser) log fsync(p0) hold(off)"))
    local rec = decode_last(S)
    report(rec.tool == "eraser" and rec.comp == "white" and rec.pat == "solid"
           and rec.st[4] == base_cfg.rubber_p_lo and rec.st[5] == base_cfg.rubber_p_hi,
           "rubber, area mode: the record is white with the rubber's pressure window",
           format("%s %s st=%s", rec.tool, rec.comp, concat(rec.st, ",")))
    S:check("rubber area")
end

do
    local S = live_session({ prefs = { mode = "erase" } })
    S:ev((visit(0, "pen", { { 500, 500 }, { 540, 500 } }, 2716)))
    local rec = decode_last(S)
    report(rec.tool == "eraser" and rec.comp == "white"
           and rec.st[4] == base_cfg.pen_p_lo and rec.st[5] == base_cfg.pen_p_hi,
           "tip, erase mode: an eraser record with the pen's pressure window",
           format("%s %s st=%s", rec.tool, rec.comp, concat(rec.st, ",")))
    local r_tip = Brush.radius(J.style(rec), 2716)
    report(r_tip > 12 and r_tip < 24, "tip, erase mode: median pressure gives a mid radius",
           num(r_tip))
    S:check("tip erase")
end

do
    local S = live_session({ prefs = { brush = "pencil" } })
    local got = S:ev((visit(0, "pen", { { 500, 500 }, { 540, 500 } }, 4095)))
    expect("pencil: darken ink with the pattern and its density", got,
           "hold(on) arm(0,0,1872,1404/0x00) ink(darken/bayer4/1) publish "
           .. "ink(darken/bayer4/1) publish append(p0 s1 pen) log fsync(p0) hold(off)")
    local rec = decode_last(S)
    report(rec.comp == "darken" and rec.pat == "bayer4" and rec.brush == "pencil",
           "pencil: the record keeps darken and bayer4")
    S:check("pencil")
end

------------------------------------------------------------------------
-- fsync only out of range
------------------------------------------------------------------------

do
    local S = live_session()
    local got = S:ev(hover_in(0, "pen", 300, 300))
    local t = 10
    for i = 1, 3 do
        local evs, t_up = down(t, { { 300, 300 + 100 * i }, { 400, 300 + 100 * i } })
        append_all(got, S:ev(evs))
        t = t_up + 30
    end
    -- The pen flips to the rubber inside one report: it never left range.
    append_all(got, S:ev(pen(t, "PEN", 0, "RUBBER", 1)))
    append_all(got, S:ev((down(t + 10, { { 900, 900 } }, 500))))
    append_all(got, S:ev(hover_out(t + 40, "rubber")))
    expect("fsync: three strokes and a tool switch in range, one fsync at prox out",
           got, j("hold(on)", ARM,
                  INK, INK, "append(p0 s1 pen) log",
                  INK, INK, "append(p0 s2 pen) log",
                  INK, INK, "append(p0 s3 pen) log",
                  WHITE, "append(p0 s4 eraser) log fsync(p0) hold(off)"))
    S:check("fsync timing")
end

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev((down(10, { { 300, 300 } })))
    local got = S:run("close")
    expect("close while hovering: fsync, disarm, release the hold, save the place", got,
           "fsync(p0) disarm hold(off) prefs(-,-,-,- last p=0)")
    got = S:ev(pen(100, "X", RX(310)))
    expect("after close: events produce nothing", got, "")
    S:check("close")
end

------------------------------------------------------------------------
-- io_error
------------------------------------------------------------------------

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev((down(10, { { 300, 300 }, { 320, 300 } })))
    local got = S:run("io_error", "ENOSPC /data/notebooks/" .. ID .. "/page-0.jsonl")
    expect("io_error: log, disarm, one toast", got, "log disarm toast")
    got = S:ev((down(2000, { { 300, 500 }, { 320, 500 } })))
    expect("io_error: a later stroke inks and records nothing; activity still counts",
           got, "activity", {})
    got = S:ev(hover_out(2100, "pen"))
    expect("io_error: earlier appends still get their fsync at prox out", got,
           "fsync(p0) hold(off)")
    got = S:ev(three(S.K, 3000, { { 1400, 400 }, { 1400, 600 }, { 1400, 800 } },
                     -400, 0, 5, 20))
    expect("io_error: undo is refused with a toast", got, "toast")
    got = S:ev(finger(S.K, 5000, 1400, 700, 900, 700, 5, 30))
    append_all(got, S:loaded(1))
    expect("io_error: pages still turn", got,
           "disarm load(p1) disarm render(p1 0) repaint washer")
    got = S:ev(visit(7000, "pen", { { 500, 500 }, { 520, 500 } }))
    expect("io_error: no arm at prox in either", got, "hold(on) hold(off)")
    got = S:run("io_error", "EIO again")
    expect("io_error: a second error logs, no second toast", got, "log")
    S:check("io_error")
end

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local evs = down(10, { { 300, 300 }, { 320, 300 }, { 340, 300 }, { 360, 300 } })
    local got = S:ev(slice(evs, 1, 9))
    append_all(got, S:run("io_error", "EIO /data/notebooks"))
    append_all(got, S:ev(slice(evs, 10)))
    -- What the two inked samples covered, which the render takes back.
    local y300 = G.raw_to_px(RY(300), YMAX, H)
    local R = region_of({ Brush.bbox(Brush.style("fine", "M", "pen", base_cfg),
        { { x = G.raw_to_px(RX(300), XMAX, W), y = y300, p = 2000 },
          { x = G.raw_to_px(RX(320), XMAX, W), y = y300, p = 2000 } }) })
    expect("io_error mid-stroke: the stroke is dropped and its ink rebuilt away", got,
           j(INK, INK, "log disarm toast render(p0 0 " .. rect(R) .. ")",
             "repaint(" .. rect(R) .. ")"))
    report(S.appends == 0 and S.logs == 1, "io_error mid-stroke: no append, no pen-up log")
    S:check("io_error mid-stroke")
end

------------------------------------------------------------------------
-- Page turns
------------------------------------------------------------------------

do
    local S = live_session()
    local got = S:ev(finger(S.K, 0, 1400, 700, 900, 700, 5, 30))
    expect("swipe left: disarm, load the next page", got, "disarm load(p1)")
    got = S:loaded(1)
    expect("page loaded: render, repaint, charge the washer", got,
           "disarm render(p1 0) repaint washer")
    got = S:ev(finger(S.K, 1000, 500, 700, 1000, 700, 5, 30))
    append_all(got, S:loaded(0))
    append_all(got, S:ev(finger(S.K, 2000, 500, 700, 1000, 700, 5, 30)))
    append_all(got, S:loaded(-1))
    expect("swipe right twice: back to 0, then to -1", got,
           "disarm load(p0) disarm render(p0 0) repaint washer "
           .. "disarm load(p-1) disarm render(p-1 0) repaint washer")
    got = S:ev(finger(S.K, 3000, 900, 300, 900, 1000, 5, 30))
    expect("a vertical swipe turns nothing", got, "")
    got = S:ev(tap_at(S.K, 4000, 900, 700))
    expect("a tap on the canvas does nothing", got, "")
    -- Two turns before the first load lands: the first answer is stale.
    got = S:ev(finger(S.K, 5000, 1400, 700, 900, 700, 5, 30))
    append_all(got, S:ev(finger(S.K, 6000, 1400, 700, 900, 700, 5, 30)))
    append_all(got, S:loaded(0))
    append_all(got, S:loaded(1))
    expect("two quick turns: the stale load is dropped, one render, one washer charge",
           got, "disarm load(p0) disarm load(p1) disarm render(p1 0) repaint washer")
    got = S:ev(finger(S.K, 7000, 1400, 700, 900, 700, 5, 30))
    append_all(got, S:run("page_loaded", 2, nil, "EIO /data/notebooks/x/page-2.jsonl"))
    append_all(got, S:ev(finger(S.K, 8000, 1400, 700, 900, 700, 5, 30)))
    expect("a failed load toasts, leaves the page, and the next turn starts from it",
           got, "disarm load(p2) toast disarm load(p2)")
    report(S.washers == 4, "one washer charge per page shown: 1, 0, -1, 1", num(S.washers))
    S:check("page turns")
end

do
    -- Blocked under a down pen.  nb_input vetoes touch while the pen is
    -- in range, so these intents are injected at the dispatcher, as a
    -- same-batch drain could deliver them.
    local S = live_session()
    S:long_press(0, 900, 700)
    local nx, ny = S:button("page:next")
    local bx, by = S:button("brush:marker")
    S:ev(hover_in(2000, "pen", 300, 300))
    S:ev(pen(2010, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300)))
    local out = {}
    S.c:_run({ { k = "swipe", dx = -600, dy = 0, t = ms(2012) },
               { k = "multi_swipe", dx = -600, dy = 0, fingers = 3, t = ms(2012) },
               { k = "long_press", x = 300, y = 900, t = ms(2012) },
               { k = "tap", x = nx, y = ny, t = ms(2012), target = "panel" },
               { k = "tap", x = bx, y = by, t = ms(2012), target = "panel" } }, out)
    expect("pen down: swipe, multi-swipe, long press, a page button and a brush button "
           .. "all do nothing", out, "")
    S:ev(pen(2020, "TOUCH", 0))
    out = {}
    S.c:_run({ { k = "swipe", dx = -600, dy = 0, t = ms(2030) } }, out)
    expect("pen up again: the same swipe turns", out, "disarm load(p1)")
end

do
    -- A load that lands under a down pen waits for pen-up; the stroke
    -- belongs to the page it started on.
    local S = live_session()
    local got = S:ev(finger(S.K, 0, 1400, 700, 900, 700, 5, 30))
    expect("load under the pen: the turn", got, "disarm load(p1)")
    got = S:ev(hover_in(300, "pen", 500, 500))
    local evs = down(310, { { 500, 500 }, { 540, 500 }, { 580, 500 } })
    append_all(got, S:ev(slice(evs, 1, 5)))
    append_all(got, S:loaded(1))
    append_all(got, S:ev(slice(evs, 6)))
    expect("load under the pen: the page waits; the stroke goes to page 0, "
           .. "then page 1 shows",
           got, j("hold(on)", ARM, INK, INK, INK, "append(p0 s1 pen) log",
                  "disarm render(p1 0) repaint washer"))
    got = S:ev((down(400, { { 700, 700 } })))
    expect("load under the pen: the next stroke re-arms and lands on page 1", got,
           "arm(0,0,1872,1404/0x00) ink(black/solid) publish append(p1 s1 pen) log")
    got = S:ev(hover_out(450, "pen"))
    expect("load under the pen: both pages written get their fsync, in order", got,
           "fsync(p0) fsync(p1) hold(off)")
    S:check("load under the pen")
end

------------------------------------------------------------------------
-- Undo and redo
------------------------------------------------------------------------

do
    local S = live_session({ prefs = { brush = "ballpoint" } })
    S:ev((visit(0, "pen", { { 200, 300 }, { 400, 300 } })))
    S:ev((visit(100, "pen", { { 1200, 900 }, { 1400, 900 } })))
    local B = S:replay(0).strokes[2]
    local R = rect(region_of(B.bb))
    local got = S:ev(three(S.K, 1000, LEFT3, -400, 0, 5, 20))
    expect("undo by three-finger swipe left: append, disarm, a render bounded by B, "
           .. "repaint, fsync",
           got, j("append(p0 u2) disarm render(p0 1 " .. R .. ")",
                  "repaint(" .. R .. ") fsync(p0)"))
    got = S:ev(three(S.K, 2000, RIGHT3, 400, 0, 5, 20))
    expect("redo by three-finger swipe right", got,
           "append(p0 r2) disarm render(p0 2 " .. R .. ") repaint(" .. R .. ") fsync(p0)")
    got = S:ev(three(S.K, 3000, LEFT3, -400, 0, 5, 20))
    append_all(got, S:ev(three(S.K, 4000, LEFT3, -400, 0, 5, 20)))
    append_all(got, S:ev(three(S.K, 5000, LEFT3, -400, 0, 5, 20)))
    report(#ops(got, "append") == 2 and #S:replay(0).strokes == 0,
           "undo: twice empties the page; a third has no target and does nothing",
           seq(got))
    got = S:ev((visit(6000, "pen", { { 800, 1200 }, { 900, 1200 } })))
    local page = S:replay(0)
    report(page.redo_target == nil and #page.strokes == 1 and page.strokes[1].a == 3,
           "new ink after undo clears redo", format("stroke a=%d", page.strokes[1].a))
    got = S:ev(three(S.K, 7000, RIGHT3, 400, 0, 5, 20))
    expect("redo with an empty redo stack does nothing", got, "")
    got = S:ev(three(S.K, 8000, { { 600, 300 }, { 800, 300 }, { 1000, 300 } },
                     0, 500, 5, 20))
    expect("a vertical three-finger swipe does nothing", got, "")
    S:check("undo and redo")
end

do
    local S = live_session()
    S:ev((visit(0, "pen", { { 200, 300 }, { 400, 300 } })))
    S:ev((visit(100, "pen", { { 1200, 1100 }, { 1400, 1100 } })))
    S:long_press(1000, 900, 700)
    local pxy = seq({ { op = "panel", layout = S.layout } })
    local got = S:tap_button("undo", 2000)
    local R = rect(region_of(J.decode(S.lines[0][2]).bb))
    expect("the Undo button: append, disarm, render, the panel re-laid out, repaint, fsync",
           got, "append(p0 u2) disarm render(p0 1 " .. R .. ") " .. pxy .. " repaint("
                .. R .. ") fsync(p0)")
    local by = {}
    for _, it in ipairs(S.layout.items) do by[it.id] = it end
    report(by.undo.enabled and by.redo.enabled, "after Undo the panel enables Redo")
    got = S:tap_button("redo", 2500)
    expect("the Redo button", got, "append(p0 r2) disarm render(p0 2 " .. R .. ") " .. pxy
           .. " repaint(" .. R .. ") fsync(p0)")
    for _, it in ipairs(S.layout.items) do by[it.id] = it end
    report(by.undo.enabled and not by.redo.enabled, "after Redo the panel disables Redo")
    S:check("undo buttons")
end

------------------------------------------------------------------------
-- The panel
------------------------------------------------------------------------

local function ref_layout(r, lx, ly, st)
    local pn = Panel.new(base_cfg)
    local lw, lh = G.logical_size(r, W, H)
    pn:set_screen(lw, lh)
    pn:open(lx, ly, lw, lh)
    return pn:layout(st or {})
end

do
    local S = live_session()
    local got = S:ev(S.K.frame(0, { { 0, id = tid(), x = 900, y = 700 } }))
    expect("long press: the landing asks for the timer", got, "schedule(700000)",
           SHOW_TIMER)
    got = S:ev({ { timer = ms(300) } })
    expect("long press: an early timer asks for the rest", got, "schedule(400000)",
           SHOW_TIMER)
    got = S:ev({ { timer = ms(700) } })
    local L = ref_layout(0, 900, 700)
    expect("long press: the panel opens centred on the press", got,
           format("disarm panel(%d,%d)", L.x, L.y))
    got = S:ev(S.K.frame(900, { { 0, id = -1 } }))
    expect("long press: the lift adds nothing", got, "")
    report(S.layout.items[1].label == "Test - page 0",
           "the panel's title names the notebook and page",
           S.layout.items[1].label)

    local pos = format("panel(%d,%d)", L.x, L.y)
    got = S:tap_button("brush:pencil", 2000)
    expect("tap a brush: the panel updates, then the prefs are saved", got,
           "disarm " .. pos .. " prefs(pencil,-,-,- last)")
    got = S:tap_button("brush:pencil", 2200)
    expect("tap the brush already chosen: nothing", got, "")
    got = S:tap_button("size:L", 2400)
    append_all(got, S:tap_button("mode:erase", 2600))
    append_all(got, S:tap_button("rubber:stroke", 2800))
    expect("size, mode and rubber choices", got,
           "disarm " .. pos .. " prefs(pencil,L,-,- last) "
           .. "disarm " .. pos .. " prefs(pencil,L,erase,- last) "
           .. "disarm " .. pos .. " prefs(pencil,L,erase,stroke last)")
    local by = {}
    for _, it in ipairs(S.layout.items) do by[it.id] = it end
    report(by["brush:pencil"].checked and by["size:L"].checked and by["mode:erase"].checked
           and by["rubber:stroke"].checked and not by["brush:fine"].checked,
           "the panel shows the choices checked")
    got = S:tap_button("mode:write", 3000)

    -- The pen with the panel open: the panel's rect is armed at 0x20.
    got = S:ev(hover_in(4000, "pen", 200, 200))
    local px, py, pw, ph = G.rect_to_physical(0, W, H, L.x, L.y, L.w, L.h)
    expect("prox in with the panel open: the panel's rect at 0x20 after the canvas", got,
           format("hold(on) arm(0,0,1872,1404/0x00;%d,%d,%d,%d/0x20)", px, py, pw, ph))
    got = S:ev((down(4010, { { 200, 200 }, { 220, 200 } })))
    expect("a stroke with the panel open: Undo turns on, but the panel waits", got,
           j("ink(darken/bayer4/0.633) publish ink(darken/bayer4/0.633) publish",
             "append(p0 s1 pen) log"))
    local ux, uy = G.to_logical(0, W, H, S:button("undo"))
    report(S.c.pn:hit(ux, uy) == "undo", "the panel's hit test already has Undo enabled")
    got = S:ev(hover_out(4100, "pen"))
    expect("prox out: fsync, then the waiting panel update, then the hold", got,
           "fsync(p0) disarm " .. pos .. " hold(off)")

    -- Drag by the title bar.
    local tx, ty = S:button("title")
    got = S:ev(finger(S.K, 5000, tx, ty, tx + 100, ty + 50, 5, 40))
    local moved = {}
    for _, c in ipairs(ops(got, "panel")) do moved[#moved + 1] = fmt(c) end
    -- The first 22 px are inside the tap slop; the drag starts at the
    -- second move, from the landing point, so the panel keeps up.
    report(#moved == 4 and moved[1] == format("panel(%d,%d)", L.x + 40, L.y + 20)
           and moved[4] == format("panel(%d,%d)", L.x + 100, L.y + 50)
           and #ops(got, "disarm") == 4,
           "drag the title: the panel follows the finger, disarm before each move",
           concat(moved, " "))
    -- A drag from the body moves nothing; a fast one flicks the panel away.
    local bx, by2 = S:button("nb:close")
    got = S:ev(finger(S.K, 6000, bx, by2 + 40, bx - 200, by2 + 40, 5, 60))
    expect("a slow drag from the body: nothing", got, "")
    got = S:ev(finger(S.K, 7000, tx + 100, ty + 50, tx + 500, ty + 50, 4, 10))
    local steps_to = {}
    for i = 1, 4 do
        steps_to[i] = format("disarm panel(%d,%d)", L.x + 100 + 100 * i, L.y + 50)
    end
    expect("a flick of the title: the panel follows, then hides at the lift", got,
           concat(steps_to, " ") .. " disarm panel(hide)")

    S:long_press(9000, 400, 300)
    local L2 = ref_layout(0, 400, 300)
    report(S.layout and S.layout.x == L2.x and S.layout.y == L2.y,
           "a long press opens the panel again, at the new point")
    got = S:tap_button("close", 10000)
    expect("the Close button hides the panel", got, "disarm panel(hide)")

    S:long_press(11000, 900, 700)
    got = S:tap_button("page:next", 12000)
    append_all(got, S:loaded(1))
    expect("page:next: the turn; the panel shows the new page", got,
           "disarm load(p1) disarm render(p1 0) " .. pos .. " repaint washer")
    report(S.layout.items[1].label == "Test - page 1", "the title follows the page",
           S.layout.items[1].label)
    got = S:tap_button("page:prev", 12500)
    append_all(got, S:loaded(0))
    expect("page:prev", got,
           j("disarm load(p0) disarm render(p0 1)", pos, "repaint washer"))
    got = S:tap_button("nb:new", 13000)
    append_all(got, S:tap_button("nb:open", 13200))
    append_all(got, S:tap_button("nb:close", 13400))
    expect("New, Open and Exit", got, "new_notebook open_list close_notebook")
    -- A long press that lands on the panel is a panel contact: no reopen.
    local ttx, tty = S:button("title")
    got = S:long_press(14000, ttx, tty)
    expect("a long press on the panel does nothing", got, "")
    S:check("panel")
end

------------------------------------------------------------------------
-- Rotation
------------------------------------------------------------------------

do
    for m = 0, 3 do
        local r = G.bb_rotation(m)
        local lw, lh = G.logical_size(r, W, H)
        local function P(lx, ly) return G.to_physical(r, W, H, floor(lx), floor(ly)) end
        local S = live_session({ mode = m })
        S:ev((visit(0, "pen", { { 900, 700 }, { 950, 700 } })))
        local acts = {}
        local function logical_swipe(t, lx0, ly0, lx1, ly1)
            local x0, y0 = P(lx0, ly0)
            local x1, y1 = P(lx1, ly1)
            return S:ev(finger(S.K, t, x0, y0, x1, y1, 5, 30))
        end
        local function logical_three(t, ldx)
            local starts = {}
            for i, f in ipairs({ 0.3, 0.5, 0.7 }) do
                starts[i] = { P(lw * (ldx < 0 and 0.75 or 0.25), lh * f) }
            end
            local x0, y0 = P(0, 0)
            local x1, y1 = P(ldx, 0)
            return S:ev(three(S.K, t, starts, x1 - x0, y1 - y0, 5, 20))
        end
        acts[#acts + 1] = seq(logical_three(1000, -lw * 0.3))
        acts[#acts + 1] = seq(logical_three(2000, lw * 0.3))
        local got = logical_swipe(3000, lw * 0.75, lh * 0.5, lw * 0.25, lh * 0.5)
        append_all(got, S:loaded(1))
        acts[#acts + 1] = seq(got)
        got = logical_swipe(4000, lw * 0.25, lh * 0.5, lw * 0.75, lh * 0.5)
        append_all(got, S:loaded(0))
        acts[#acts + 1] = seq(got)
        acts[#acts + 1] = seq(logical_swipe(5000, lw * 0.5, lh * 0.2, lw * 0.5, lh * 0.8))
        local ok_m = acts[1]:match("^append%(p0 u1%)")
                     and acts[2]:match("^append%(p0 r1%)")
                     and acts[3]:match("^disarm load%(p1%)")
                     and acts[4]:match("^disarm load%(p0%)")
                     and acts[5] == ""
        -- The panel opens where the finger pressed, in logical px.
        S:long_press(6000, P(lw * 0.3, lh * 0.4))
        local L = ref_layout(r, lw * 0.3, lh * 0.4)
        ok_m = ok_m and S.layout and S.layout.x == L.x and S.layout.y == L.y
        report(ok_m and true or false,
               format("rotation mode %d: logical left undoes and turns forward, right "
                      .. "redoes and turns back, vertical does nothing, the panel "
                      .. "opens at the press", m),
               concat(acts, " | "))
        S:check(format("rotation mode %d", m))
    end
end

do
    -- set_rotation: only a real change re-lays out the panel.
    local S = live_session({ mode = 0 })
    expect("set_rotation to the current mode: nothing", S:run("set_rotation", 0), "")
    expect("set_rotation with the panel closed: nothing to show",
           S:run("set_rotation", 1), "")
    S:long_press(0, 700, 900)
    local got = S:run("set_rotation", 2)
    local pn = Panel.new(base_cfg)
    pn:set_screen(H, W)
    local lx, ly = G.to_logical(3, W, H, 700, 900)
    pn:open(lx, ly, H, W)
    pn:set_screen(W, H)
    local L = pn:layout({})
    expect("set_rotation with the panel open: disarm, the panel re-clamped "
           .. "for the new screen",
           got, format("disarm panel(%d,%d)", L.x, L.y))
    -- Swipes follow the new rotation: mode 2 is bb rotation 2, so a
    -- physical rightward swipe is logical left.
    got = S:ev(finger(S.K, 2000, 300, 1200, 800, 1200, 5, 30))
    expect("after set_rotation(2) a physical right swipe is logical left: next page", got,
           "disarm load(p1)")
    S:check("set_rotation")
end

------------------------------------------------------------------------
-- A leave waits prox_leave_us: proximity dropouts
------------------------------------------------------------------------

do
    -- pen-1's Y=0 edge: contact, pressure and proximity go in one report
    -- and come back 22 ms later at full pressure, the nib never lifted.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 700))
    local got = S:ev(steps(
        pen(10, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(700)),
        pen(13, "X", RX(320)),
        pen(16, "TOUCH", 0, "P", 0, "PEN", 0)))
    expect("dropout: the half-stroke is recorded with its gap; no fsync, hold kept", got,
           j(INK, INK, "append(p0 s1 pen gap) log"))
    got = S:ev(steps(
        pen(38, "PEN", 1, "TOUCH", 1, "P", 4095, "X", RX(330), "Y", RY(700)),
        pen(41, "X", RX(350)), pen(100, "X", RX(380))))
    expect("dropout: back 22 ms later, a new stroke; nothing to arm or hold again", got,
           j(INK, INK, INK))
    got = S:ev({ { timer = ms(16 + LEAVE_MS) } })
    expect("dropout: the timer it asked for finds the pen back and does nothing", got, "")
    got = S:ev(steps(pen(170, "X", RX(400)), pen(173, "TOUCH", 0, "P", 0)))
    expect("dropout: the second half is its own record", got,
           j(INK, "append(p0 s2 pen) log"))
    got = S:ev(prox_out(180, "pen"))
    expect("the real prox-out: nothing yet", got, "")
    got = S:ev({ { timer = ms(180 + LEAVE_MS) } })
    expect("the leave: one fsync for both halves, then the hold released", got,
           "fsync(p0) hold(off)")
    local l = S.lines[0]
    local r1, r2 = J.decode(l[1]), J.decode(l[2])
    report(#l == 2 and r1.gap == 1 and r2.gap == 0,
           "dropout: two records, the first with its gap flag", format("%d lines", #l))
    S:check("dropout")
end

do
    -- The pen-3 and pen-4 hover flicker (40-44 ms), and a leave that lands
    -- mid-window when the timer runs early.
    local S = live_session()
    S:ev(visit(0, "pen", { { 500, 500 }, { 520, 500 } }))
    S:ev(hover_in(400, "pen", 500, 600))
    S:ev((down(410, { { 500, 600 }, { 520, 600 } })))
    local got = S:ev(prox_out(430, "pen"))
    append_all(got, S:ev(hover_in(474, "pen", 520, 600)))
    expect("hover flicker: out and back in 44 ms is no leave", got, "")
    got = S:ev(prox_out(500, "pen"))
    append_all(got, S:ev({ { timer = ms(560) } }))
    expect("prox-out asks for the window; a timer run before it ends asks for the rest",
           got, "schedule(150000) schedule(90500)", SHOW_TIMER)
    got = S:ev({ { timer = ms(500 + LEAVE_MS) } })
    expect("then the leave", got, "fsync(p0) hold(off)")
    S:check("hover flicker")
end

do
    -- Suspend while a leave is pending runs it, without repainting; the
    -- timer then finds nothing.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev((down(10, { { 300, 300 }, { 320, 300 } })))
    S:ev(prox_out(30, "pen"))
    local got = S:run("suspend")
    expect("suspend mid-window: the leave's fsync and release, then disarm and the place",
           got, "fsync(p0) hold(off) disarm prefs(-,-,-,- last p=0)")
    got = S:ev({ { timer = ms(30 + LEAVE_MS) } })
    expect("the window's timer after suspend: nothing", got, "")
    S:check("suspend mid-window")
end

do
    -- The glue has one timer: a long press asked for while a leave is
    -- pending gets the sooner deadline, and asks again for its rest.
    -- palm_grace_us 0, so a touch can land inside the window at all.
    local cfg = setmetatable({ palm_grace_us = 0 }, { __index = base_cfg })
    local S = live_session({ cfg = cfg })
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev(prox_out(100, "pen"))
    local got = S:ev(S.K.frame(120, { { 0, id = tid(), x = 900, y = 700 } }))
    expect("one timer: a long press inside the leave window asks for the leave's deadline",
           got, "schedule(130000)", SHOW_TIMER)
    got = S:ev({ { timer = ms(100) + 500 + 150000 } })
    expect("one timer: the leave runs, and the long press asks for its rest", got,
           "hold(off) schedule(569500)", SHOW_TIMER)
    got = S:ev({ { timer = ms(820) } })
    report(#ops(got, "panel") == 1 and S.c.pn:is_open(),
           "one timer: the long press still opens the panel", seq(got, SHOW_TIMER))
    S:check("one timer")
end

do
    -- A palm resting before the pen comes into range: its long press
    -- fires by timer, and the pen's arrival with the palm still down takes
    -- the panel back.  A real long press, lifted before the pen comes,
    -- keeps it.
    local S = live_session()
    S:ev(S.K.frame(1000, { { 0, id = tid(), x = 900, y = 700 } }))
    local got = S:ev({ { timer = ms(1700) } })
    report(#ops(got, "panel") == 1 and S.c.pn:is_open(),
           "palm first: the resting contact's long press opens the panel", seq(got))
    got = S:ev(hover_in(1900, "pen", 300, 300))
    report(S.layout == nil and not S.c.pn:is_open()
           and seq(got):match("^hold%(on%) arm%([^)]*%) disarm panel%(hide%)$") ~= nil,
           "palm first: the pen arriving under the palm closes the panel it opened",
           seq(got))
    got = S:ev(S.K.frame(2000, { { 0, id = -1 } }))
    expect("palm first: the palm's lift does nothing", got, "")
    got = S:ev((down(2010, { { 300, 300 }, { 320, 300 } })))
    expect("palm first: the first ink re-arms the canvas alone", got,
           j(ARM, INK, INK, "append(p0 s1 pen) log"))
    S:ev(hover_out(2100, "pen"))
    S:long_press(3000, 900, 700)
    got = S:ev(hover_in(4000, "pen", 300, 300))
    report(S.c.pn:is_open() and #ops(got, "panel") == 0,
           "a long press lifted before the pen comes keeps its panel", seq(got))
    S:check("palm first")
end

------------------------------------------------------------------------
-- Palm rejection
------------------------------------------------------------------------

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local got = S:ev(finger(S.K, 100, 1400, 700, 900, 700, 5, 30))
    expect("palm: a swipe while the pen hovers does nothing", got, "")
    got = S:ev(S.K.frame(500, { { 0, id = tid(), x = 900, y = 700 } }))
    append_all(got, S:ev({ { timer = ms(1200) } }))
    append_all(got, S:ev(S.K.frame(1300, { { 0, id = -1 } })))
    expect("palm: a long press while the pen hovers does nothing", got, "")
    S:ev(hover_out(2000, "pen"))
    got = S:ev(finger(S.K, 2300, 1400, 700, 900, 700, 5, 30))
    expect("palm: a swipe starting within the grace after prox out does nothing", got, "")
    got = S:ev(finger(S.K, 3000, 1400, 700, 900, 700, 5, 30))
    expect("palm: a swipe starting after the grace turns", got, "disarm load(p1)")
    S:loaded(1)
    -- The palm lands first, then the pen arrives: vetoed at the end.
    local evs = finger(S.K, 4000, 1400, 700, 900, 700, 5, 30)
    got = S:ev(slice(evs, 1, 8))
    append_all(got, S:ev(hover_in(4070, "pen", 300, 300)))
    append_all(got, S:ev(slice(evs, 9)))
    expect("palm: a swipe the pen arrives during does nothing", got,
           "hold(on) arm(0,0,1872,1404/0x00)")
    S:ev(hover_out(4300, "pen"))
    evs = three(S.K, 5000, LEFT3, -400, 0, 5, 20)
    got = S:ev(slice(evs, 1, 20))
    append_all(got, S:ev(hover_in(5050, "pen", 300, 300)))
    append_all(got, S:ev(slice(evs, 21)))
    expect("palm: a three-finger swipe the pen arrives during does nothing", got,
           "hold(on)")
    S:ev(hover_out(5300, "pen"))
    got = S:ev(S.K.frame(6000, { { 0, id = tid(), x = 900, y = 700 } }))
    append_all(got, S:ev(hover_in(6300, "pen", 300, 300)))
    append_all(got, S:ev({ { timer = ms(6700) } }))
    append_all(got, S:ev(S.K.frame(6800, { { 0, id = -1 } })))
    expect("palm: a long press the pen arrives during opens nothing", got,
           "schedule(700000) hold(on)", SHOW_TIMER)
    S:ev(hover_out(6900, "pen"))
    -- A title drag the pen interrupts ends where it is, never as a flick.
    S:long_press(8000, 900, 700)
    local L0 = S.layout
    local tx, ty = S:button("title")
    evs = finger(S.K, 9000, tx, ty, tx + 400, ty, 4, 10)
    got = S:ev(slice(evs, 1, 12))
    append_all(got, S:ev(hover_in(9025, "pen", 300, 300)))
    append_all(got, S:ev(slice(evs, 13)))
    report(#ops(got, "panel") >= 1 and S.layout ~= nil and S.layout.x > L0.x,
           "palm: a title drag the pen interrupts leaves the panel where it was dragged",
           seq(got))
    S:check("palm")
end

------------------------------------------------------------------------
-- Ink going dead, suspend, resume, SYN_DROPPED
------------------------------------------------------------------------

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local evs = down(10, { { 300, 300 }, { 330, 300 }, { 360, 300 }, { 390, 300 } })
    local got = S:ev(slice(evs, 1, 9))
    append_all(got, S:run("set_ink_live", false))
    append_all(got, S:ev(slice(evs, 10)))
    expect("ink goes dead mid-stroke: what was drawn is recorded (gap), the rest dropped",
           got, j(INK, INK, "append(p0 s1 pen gap) log disarm"))
    got = S:run("set_ink_live", true)
    append_all(got, S:ev((down(100, { { 300, 500 } }))))
    expect("ink live again with the pen in range: arm, then ink", got,
           "arm(0,0,1872,1404/0x00) ink(black/solid) publish append(p0 s2 pen) log")
    S:check("ink dead")
end

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local evs = down(10, { { 300, 300 }, { 330, 300 }, { 360, 300 } })
    S:ev(slice(evs, 1, 9))
    local got = S:run("suspend")
    expect("suspend mid-stroke: record it, fsync, disarm, save the place", got,
           "append(p0 s1 pen gap) log fsync(p0) disarm prefs(-,-,-,- last p=0)")
    got = S:ev(slice(evs, 10))
    expect("suspended: nothing inks", got, "")
    NOW = ms(60000)
    got = S:run("resume", { prox = true, tool = "pen", touching = false })
    expect("resume with the pen in range: arm again", got, "arm(0,0,1872,1404/0x00)")
    got = S:run("suspend")
    append_all(got, S:run("resume", { prox = false, tool = nil, touching = false }))
    append_all(got, S:ev({ { timer = ms(60000 + LEAVE_MS) } }))
    expect("suspend and resume with the pen gone: disarm, then the leave releases the hold",
           got, "disarm hold(off)")
    S:check("suspend")
end

do
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local evs = down(10, { { 300, 300 }, { 330, 300 }, { 360, 300 }, { 390, 300 } })
    local got = S:ev(slice(evs, 1, 9))
    append_all(got, S:ev(pen_drop(16)))
    append_all(got, S:ev(pen(16, "X", RX(360))))
    expect("pen SYN_DROPPED: the stroke ends with a gap; the next report asks for a resync",
           got, j(INK, INK, "append(p0 s1 pen gap) log resync_pen"))
    report(S.log_lines[1]:match(" gap=1 ") and S.log_lines[1]:match(" drops=1 ") ~= nil,
           "pen SYN_DROPPED: counted in the pen-up log", S.log_lines[1])
    got = S:run("resync", { prox = true, tool = "pen", touching = true }, ms(18))
    append_all(got, S:ev(pen(19, "X", RX(390))))
    append_all(got, S:ev(pen(22, "TOUCH", 0)))
    expect("after the resync a pen still down inks nothing until a real contact", got, "")
    got = S:ev((down(40, { { 500, 500 } })))
    expect("the next real contact inks", got, j(INK, "append(p0 s2 pen) log"))
    report(S.log_lines[2]:match(" drops=0 ") ~= nil, "drops reset after each log line")
    S:check("SYN_DROPPED")
end

------------------------------------------------------------------------
-- Guards
------------------------------------------------------------------------

do
    -- A crafted page whose action ids reach past 2^31.
    local S = new_session()
    local page = J.replay({ J.encode({ k = "u", a = 2^31 + 1 }) }, base_cfg)
    S:open(0, page)
    S:run("set_ink_live", true)
    local got = S:ev((visit(0, "pen", { { 300, 300 }, { 320, 300 } })))
    append_all(got, S:ev((visit(100, "pen", { { 300, 400 } }))))
    expect("action ids past 2^31: strokes refused, one toast, no ink", got,
           "hold(on) arm(0,0,1872,1404/0x00) toast hold(off) hold(on) hold(off)")
    got = S:ev(finger(S.K, 1000, 1400, 700, 900, 700, 5, 30))
    append_all(got, S:loaded(1))
    append_all(got, S:ev((visit(2000, "pen", { { 300, 300 } }))))
    expect("the next page inks again", got,
           j("disarm load(p1) disarm render(p1 0) repaint washer hold(on)", ARM,
             INK, "append(p1 s1 pen) log fsync(p1) hold(off)"))
    S:check("action guard")
end

do
    -- Prefs from disk are cleaned to what save_prefs can encode.
    local other = "20260925T000000Z-000001"
    local S = new_session({ prefs = { brush = "bogus", size = "XL", mode = "erase",
                                      rubber = "stroke", last_id = "nope",
                                      last_page = { nope = 3, [ID] = 2.5, [other] = 4 } } })
    local got = S:open(0)
    local p = ops(got, "save_prefs")[1].prefs
    local ok = pcall(J._codec.encode_obj, p, J._codec.PREFS)
    report(ok and p.brush == nil and p.size == nil and p.mode == "erase"
           and p.rubber == "stroke" and p.last_id == ID and p.last_page[other] == 4
           and p.last_page.nope == nil and p.last_page[ID] == nil
           and S.c:_panel_state().brush == Brush.IDS[1]
           and S.c:_panel_state().size == "M",
           "prefs: unknown values are dropped and read as the defaults, bad places are "
           .. "dropped, the result encodes",
           seq(got))
end

do
    -- Every call returns a fresh array, including the empty ones.
    local S = live_session()
    local a = S.c:feed(pen(0, "X", 5)[1])
    local b = S.c:feed(pen(0, "X", 6)[1])
    local c = S.c:note_timing("stamp", 5)
    local d = S.c:set_touch_slot(2)
    report(#a == 0 and #b == 0 and a ~= b and a ~= Input.NONE and #c == 0 and c ~= a
           and #d == 0 and #Input.NONE == 0 and next(Input.NONE) == nil,
           "every call returns a new array; nb_input's NONE stays empty")
    local fresh = Ctl.new{ cfg = base_cfg, now_rt_us = now }
    local e = fresh:feed(pen(0, "X", 5)[1])
    report(#e == 0 and not fresh:is_open(), "before open, events produce nothing")
end

------------------------------------------------------------------------
-- Interactions between the rules (the adversarial review's cases)
------------------------------------------------------------------------

do
    -- The operator flips the pen without lifting it: nb_input ends the
    -- tip's stroke with a gap and reports prox off, then on, in one report.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local got = S:ev(pen(10, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300)))
    append_all(got, S:ev(pen(13, "X", RX(320))))
    append_all(got, S:ev(pen(16, "PEN", 0, "RUBBER", 1, "X", RX(340))))
    append_all(got, S:ev(pen(19, "X", RX(360))))
    append_all(got, S:ev(pen(22, "TOUCH", 0, "P", 0)))
    expect("tool switch mid-stroke: the tip's stroke is recorded with a gap; no fsync, "
           .. "the hold stays, and the rubber draws nothing until it touches",
           got, j(INK, INK, "append(p0 s1 pen gap) log"))
    got = S:ev((down(40, { { 500, 500 }, { 540, 500 } }, 500)))
    append_all(got, S:ev(hover_out(60, "rubber")))
    expect("tool switch mid-stroke: the rubber's own contact erases; one fsync at prox out",
           got, j(WHITE, WHITE, "append(p0 s2 eraser) log fsync(p0) hold(off)"))
    S:check("tool switch mid-stroke")
end

do
    -- The same switch with a page load pending: the switch's stroke_end is
    -- the pen-up the load waited for, with the pen still in range.
    local S = live_session()
    S:ev(finger(S.K, 0, 1400, 700, 900, 700, 5, 30))
    S:ev(hover_in(1000, "pen", 300, 300))
    local got = S:ev(pen(1010, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300)))
    append_all(got, S:loaded(1))
    append_all(got, S:ev(pen(1013, "PEN", 0, "RUBBER", 1, "X", RX(340))))
    expect("tool switch under a pending load: the stroke goes to page 0, then page 1 shows",
           got, j(INK, "append(p0 s1 pen gap) log disarm render(p1 0) repaint washer"))
    got = S:ev(pen(1020, "TOUCH", 0))
    append_all(got, S:ev((down(1030, { { 500, 500 } }, 500))))
    append_all(got, S:ev(hover_out(1050, "rubber")))
    expect("tool switch under a pending load: the rubber re-arms on page 1; both pages synced",
           got, j(ARM, WHITE, "append(p1 s1 eraser) log fsync(p0) fsync(p1) hold(off)"))
    S:check("tool switch under a load")
end

do
    -- A stroke that starts while a turn is loading belongs to the page on
    -- screen; the load that lands after its pen-up shows at once.
    local S = live_session()
    local got = S:ev(finger(S.K, 0, 1400, 700, 900, 700, 5, 30))
    append_all(got, S:ev((visit(600, "pen", { { 300, 300 }, { 340, 300 } }))))
    append_all(got, S:loaded(1))
    expect("a stroke during a load: recorded on page 0, then page 1 shows", got,
           j("disarm load(p1) hold(on)", ARM, INK, INK,
             "append(p0 s1 pen) log fsync(p0) hold(off) disarm render(p1 0) repaint washer"))
    S:check("stroke during a load")
end

do
    -- The stroke eraser under a load that lands mid-path.
    local W1 = live_session()
    three_lines(W1, 0)
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    local RB = region_of(S:replay(0).strokes[2].bb)
    S:ev(finger(S.K, 1000, 1400, 1300, 900, 1300, 5, 30))
    S:ev(hover_in(2000, "pen", 900, 650))
    local evs = down(2010, { { 900, 650 }, { 900, 750 }, { 900, 800 } })
    local got = S:ev(slice(evs, 1, 8))
    append_all(got, S:loaded(1))
    append_all(got, S:ev(slice(evs, 9)))
    expect("stroke erase under a pending load: the x record on page 0, then page 1 "
           .. "shows; page 0's waiting render is dropped with it",
           got, j(WHITE, "append(p0 x4[2]) log disarm render(p1 0) repaint washer"))
    report(S.c.erased_box == nil, "stroke erase under a pending load: nothing left waiting")
    S:check("stroke erase under a load")
end

do
    -- Undo right after a turn: dropped while the load is pending, then it
    -- acts on the page shown.
    local S = live_session()
    S:ev((visit(0, "pen", { { 300, 300 }, { 400, 300 } })))
    local left = S.c.page
    report(S.c.last_append ~= nil and S.c.last_append.page == left,
           "turn: the last append is kept for its io_error")
    local got = S:ev(finger(S.K, 1000, 1400, 700, 900, 700, 5, 30))
    -- Kept past the turn, it would hold the page left, every point of
    -- it, until the next append.
    report(S.c.last_append == nil, "turn: the page left is no longer held by the last append")
    append_all(got, S:ev(three(S.K, 1500, LEFT3, -400, 0, 5, 20)))
    expect("undo while a turn is loading does nothing", got, "disarm load(p1)")
    S:loaded(1)
    got = S:ev(three(S.K, 2500, LEFT3, -400, 0, 5, 20))
    expect("undo on the blank page turned to does nothing", got, "")
    S:ev(finger(S.K, 3500, 500, 700, 1000, 700, 5, 30))
    S:loaded(0)
    got = S:ev(three(S.K, 4500, LEFT3, -400, 0, 5, 20))
    local R = rect(region_of(S:replay(0).strokes[1] and S:replay(0).strokes[1].bb
                             or J.decode(S.lines[0][1]).bb))
    expect("undo after turning back undoes that page's stroke", got,
           j("append(p0 u1) disarm render(p0 0 " .. R .. ") repaint(" .. R .. ") fsync(p0)"))
    S:check("undo after a turn")
end

do
    -- A stroke eraser that picks nothing: no record, nothing to sync.
    local W1 = live_session()
    three_lines(W1, 0)
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    local got = S:ev((visit(1000, "pen", { { 100, 1350 }, { 200, 1350 } })))
    expect("stroke erase with no hits: a log line, no append, no fsync at prox out", got,
           j("hold(on)", ARM, "log hold(off)"))
    local line = S.log_lines[1]
    report(line:match(" rec=%- ") and line:match(" use=strokes ")
           and line:match(" hits=0 ") ~= nil,
           "stroke erase with no hits: the log says so", line)
    S:check("stroke erase, no hits")
end

do
    -- Ink going dead, and io_error, in the middle of a stroke-erase path
    -- that has already whited a stroke out.
    local W1 = live_session()
    three_lines(W1, 0)
    local lines = W1.lines[0]
    local RB = rect(region_of(W1:replay(0).strokes[2].bb))

    local S = session_on(lines, { prefs = { mode = "stroke_erase" } })
    S:ev(hover_in(1000, "pen", 900, 650))
    local evs = down(1010, { { 900, 650 }, { 900, 750 }, { 900, 800 } })
    local got = S:ev(slice(evs, 1, 8))
    append_all(got, S:run("set_ink_live", false))
    expect("ink dead mid stroke-erase: the hits so far are recorded and rendered at once, "
           .. "one disarm", got, j(WHITE, "append(p0 x4[2]) log disarm render(p0 2 " .. RB
                                   .. ")", "repaint(" .. RB .. ")"))
    local out = {}
    S.c:_run({ { k = "swipe", dx = -600, dy = 0, t = ms(1015) } }, out)
    expect("ink dead mid-stroke: the pen is still down, so nothing turns", out, "")
    got = S:ev(slice(evs, 9))
    expect("ink dead mid-stroke: the rest of that pen-down is dropped", got, "")
    S:check("ink dead mid stroke-erase")

    S = session_on(lines, { prefs = { mode = "stroke_erase" } })
    S:ev(hover_in(1000, "pen", 900, 650))
    got = S:ev(slice(evs, 1, 8))
    append_all(got, S:run("io_error", "EIO /data/notebooks"))
    append_all(got, S:ev(slice(evs, 9)))
    expect("io_error mid stroke-erase: nothing recorded; the whited-out stroke is rendered back",
           got, j(WHITE, "log disarm toast render(p0 3 " .. RB .. ") repaint(" .. RB .. ")"))
    report(S.appends == 0, "io_error mid stroke-erase: no append")
    S:check("io_error mid stroke-erase")
end

do
    -- SYN_DROPPED in the middle of a stroke-erase path keeps its hits.
    local W1 = live_session()
    three_lines(W1, 0)
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    local RB = rect(region_of(S:replay(0).strokes[2].bb))
    S:ev(hover_in(1000, "pen", 900, 650))
    local evs = down(1010, { { 900, 650 }, { 900, 750 }, { 900, 800 } })
    local got = S:ev(slice(evs, 1, 8))
    append_all(got, S:ev(pen_drop(1016)))
    expect("SYN_DROPPED mid stroke-erase: the x record keeps the hits so far; the render "
           .. "waits for the leave", got, j(WHITE, "append(p0 x4[2]) log"))
    -- The report after the drop is discarded; the key snapshot finds the
    -- pen gone.
    got = S:ev(prox_out(1100, "pen"))
    append_all(got, S:run("resync", { prox = false, touching = false }, ms(1100)))
    append_all(got, S:ev({ { timer = ms(1100 + LEAVE_MS) } }))
    expect("SYN_DROPPED mid stroke-erase: the resync's leave syncs and renders", got,
           "resync_pen fsync(p0) disarm render(p0 2 " .. RB .. ") repaint(" .. RB
           .. ") hold(off)")
    report(S.log_lines[1]:match(" drops=1 ") ~= nil, "SYN_DROPPED mid stroke-erase: logged",
           S.log_lines[1])
    S:check("SYN_DROPPED mid stroke-erase")
end

do
    -- A resync is the only way nb_input learns of a pen already in range.
    local S = live_session()
    local got = S:run("resync", { prox = true, tool = "rubber", touching = false }, ms(0))
    expect("resync finds the pen in range with ink live: hold, then arm", got,
           "hold(on) " .. ARM)
    got = S:run("resync", { prox = true, tool = "pen", touching = false }, ms(10))
    expect("resync finds the other end in range: no prox change, nothing emitted", got, "")
    got = S:ev((down(20, { { 500, 500 } })))
    expect("then the tip inks with no second arm", got, j(INK, "append(p0 s1 pen) log"))
    got = S:run("resync", { prox = false, touching = false }, ms(40))
    append_all(got, S:ev({ { timer = ms(40 + LEAVE_MS) } }))
    expect("resync finds the pen gone: the leave syncs the page written, releases the hold",
           got, "fsync(p0) hold(off)")
    S:check("resync")
end

do
    -- A controller reused after close: nothing of the old session's pen
    -- or ink predicate carries over.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:run("close")
    report(not S.c:pen_in_range() and not S.c:is_open(),
           "after close the pen reads out of range")
    local got = S:open(0)
    append_all(got, S:run("resync", { prox = true, tool = "pen", touching = false }, ms(100)))
    expect("reopen: the resync holds rotation but arms nothing before set_ink_live", got,
           "disarm render(p0 0) repaint hold(on)")
    got = S:run("set_ink_live", true)
    expect("reopen: set_ink_live(true) arms", got, ARM)
    S:check("reopen")
end

do
    -- The panel open while writing, through a suspend.
    local S = live_session()
    S:long_press(0, 900, 700)
    local pos = seq({ { op = "panel", layout = S.layout } })
    local L = S.layout
    local px, py, pw, ph = G.rect_to_physical(0, W, H, L.x, L.y, L.w, L.h)
    local ARM2 = format("arm(0,0,1872,1404/0x00;%d,%d,%d,%d/0x20)", px, py, pw, ph)
    S:ev(hover_in(2000, "pen", 200, 200))
    local got = S:ev((down(2010, { { 200, 200 }, { 240, 200 } })))
    expect("panel open: a stroke's panel update waits", got,
           j(INK, INK, "append(p0 s1 pen) log"))
    got = S:run("suspend")
    expect("suspend with the panel open: fsync, disarm, the place; the panel stays", got,
           "fsync(p0) disarm prefs(-,-,-,- last p=0)")
    report(S.layout ~= nil and S.c.pn:is_open(), "suspend leaves the panel open")
    NOW = ms(60000)
    got = S:run("resume", { prox = true, tool = "pen", touching = false })
    expect("resume with the pen in range: the canvas and the panel armed again", got, ARM2)
    got = S:ev(hover_out(60100, "pen"))
    expect("then prox out shows the waiting panel update (nothing left to sync)", got,
           j("disarm", pos, "hold(off)"))

    -- The same, but the pen leaves while the device sleeps.  An undo
    -- first, so the new stroke's cleared Redo is a change to show.
    S:ev(three(S.K, 61000, LEFT3, -400, 0, 5, 20))
    got = S:ev(hover_in(62000, "pen", 200, 400))
    append_all(got, S:ev((down(62010, { { 200, 400 } }))))
    expect("panel open: prox in arms both rects; new ink clears Redo; the update waits",
           got, j("hold(on)", ARM2, INK, "append(p0 s2 pen) log"))
    got = S:run("suspend")
    expect("suspend: the stroke synced; the place unchanged, so no prefs", got,
           "fsync(p0) disarm")
    NOW = ms(120000)
    got = S:run("resume", { prox = false, touching = false })
    append_all(got, S:ev({ { timer = ms(120000 + LEAVE_MS) } }))
    expect("resume with the pen gone: at the leave, the waiting panel update, then the "
           .. "hold released", got, j("disarm", pos, "hold(off)"))
    S:check("suspend with the panel")
end

do
    -- A rotation with the pen in range and the panel open: the arm
    -- follows the panel's new physical rect.
    local S = live_session()
    S:long_press(0, 900, 700)
    S:ev(hover_in(2000, "pen", 200, 200))
    local got = S:run("set_rotation", 1)
    local L = S.layout
    local px, py, pw, ph = G.rect_to_physical(3, W, H, L.x, L.y, L.w, L.h)
    append_all(got, S:ev((down(2010, { { 200, 200 } }))))
    expect("rotation with the pen in range: disarm and re-lay the panel; the next ink "
           .. "arms the panel's new rect",
           got, j("disarm", seq({ { op = "panel", layout = L } }),
                  format("arm(0,0,1872,1404/0x00;%d,%d,%d,%d/0x20)", px, py, pw, ph),
                  INK, "append(p0 s1 pen) log"))
    local rec = decode_last(S)
    report(rec.rot == 1, "the record keeps the rotation mode at pen-down", num(rec.rot))
    S:check("rotation in range")
end

do
    -- A rotation in the middle of a title drag ends the drag: the rest of
    -- the gesture, even a flick, does nothing.
    local S = live_session()
    S:long_press(0, 900, 700)
    local tx, ty = S:button("title")
    local evs = finger(S.K, 2000, tx, ty, tx + 500, ty, 4, 10)
    local got = S:ev(slice(evs, 1, 6))
    expect("rotation mid-drag: the drag starts", got,
           format("disarm panel(%d,%d)", S.layout.x, S.layout.y))
    got = S:run("set_rotation", 1)
    local L = S.layout
    expect("rotation mid-drag: the panel re-laid out for the new screen", got,
           format("disarm panel(%d,%d)", L.x, L.y))
    got = S:ev(slice(evs, 7))
    expect("rotation mid-drag: the rest of the drag and its flick do nothing", got, "")
    report(S.c.pn:is_open() and S.layout == L, "rotation mid-drag: the panel stays open")
    S:check("rotation mid-drag")
end

do
    -- A flick at exactly flick_min_px_per_s closes; one px/10 ms less stays.
    -- The finger crosses the slop at +100 ms, so the window (100 ms) sees
    -- only the last leg: dist px over 100 ms is dist * 10 px/s.
    local function flick(dist)
        local S = live_session()
        S:long_press(0, 900, 700)
        local tx, ty = S:button("title")
        local evs = S.K.frame(2000, { { 0, id = tid(), x = tx, y = ty } })
        append_all(evs, S.K.frame(2100, { { 0, x = tx + 30, y = ty } }))
        append_all(evs, S.K.frame(2200, { { 0, x = tx + 30 + dist, y = ty } }))
        append_all(evs, S.K.frame(2200, { { 0, id = -1 } }))
        local got = S:ev(evs)
        return seq(got), S
    end
    local at = flick(base_cfg.flick_min_px_per_s / 10)
    local below = flick(base_cfg.flick_min_px_per_s / 10 - 1)
    report(at:match("disarm panel%(hide%)$") ~= nil,
           "a flick at exactly the threshold closes the panel", at)
    report(not below:match("hide") and select(2, below:gsub("panel%(", "")) == 2,
           "a flick just below the threshold leaves it where it was dragged", below)
end

do
    -- Three fingers that land on the open panel still undo, and the panel
    -- shows the new Undo/Redo state at once.
    local S = live_session()
    S:ev((visit(0, "pen", { { 200, 300 }, { 400, 300 } })))
    S:long_press(2000, 900, 700)
    local L = S.layout
    local on_panel = { { 1300, 500 }, { 1300, 700 }, { 1300, 900 } }
    for _, p in ipairs(on_panel) do
        local lx, ly = G.to_logical(0, W, H, p[1], p[2])
        assert(S.c.pn:hit(lx, ly), "finger start not on the panel")
    end
    local R = rect(region_of(J.decode(S.lines[0][1]).bb))
    local got = S:ev(three(S.K, 4000, on_panel, -400, 0, 5, 20))
    expect("a three-finger swipe starting on the panel undoes and re-lays the panel", got,
           j("append(p0 u1) disarm render(p0 0 " .. R .. ")",
             format("panel(%d,%d)", L.x, L.y), "repaint(" .. R .. ") fsync(p0)"))
    local by = {}
    for _, it in ipairs(S.layout.items) do by[it.id] = it end
    report(not by.undo.enabled and by.redo.enabled, "the panel now offers Redo only")
    S:check("multi-swipe on the panel")
end

do
    -- Taps that land on nothing actionable.
    local S = live_session()
    S:long_press(0, 900, 700)
    local got = S:tap_button("undo", 2000)
    append_all(got, S:tap_button("redo", 2200))
    append_all(got, S:tap_button("title", 2400))
    local L = S.layout
    local bx, by = G.to_physical(0, W, H, L.x + L.w - 20, L.y + L.h - 5)
    append_all(got, S:ev(tap_at(S.K, 2600, bx, by)))
    expect("taps on disabled Undo and Redo, the title and the padding do nothing", got, "")
    got = S:long_press(3000, 200, 1300)
    local L2 = ref_layout(0, 200, 1300)
    expect("a long press on the canvas with the panel open moves it there", got,
           format("disarm panel(%d,%d)", L2.x, L2.y))
    S:check("dead taps")
end

do
    -- nb_input's shared limiter: one activity per second of writing.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    local evs = pen(10, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300))
    for i = 1, 25 do append_all(evs, pen(10 + 100 * i, "X", RX(300 + 10 * i))) end
    append_all(evs, pen(2600, "TOUCH", 0))
    local got = S:ev(evs)
    local toks = {}
    for tok in seq(got, {}):gmatch("%S+") do toks[#toks + 1] = tok end
    local idx = {}
    for i, tok in ipairs(toks) do
        if tok == "activity" then idx[#idx + 1] = i end
    end
    -- ink publish activity, then per sample ink publish; samples 10 and
    -- 20 (1 s and 2 s in) carry the next ones.
    report(#idx == 3 and idx[1] == 3 and idx[2] == 3 + 2 * 10 + 1 and idx[3] == 3 + 2 * 20 + 2,
           "activity: at pen-down, then once per second of contact", concat(idx, ","))
    local sw = S:ev(hover_out(2700, "pen"))
    append_all(sw, S:ev(finger(S.K, 3100, 1400, 700, 900, 700, 5, 30)))
    report(select(2, seq(sw, {}):gsub("activity", "")) == 0,
           "activity: a touch inside the grace is a palm and counts for nothing")
    sw = S:ev(finger(S.K, 3700, 1400, 700, 900, 700, 5, 30))
    report(seq(sw, {}):match("^schedule%(700000%) activity") ~= nil,
           "activity: an accepted touch 1.7 s after the last counts", seq(sw, {}))
end

do
    -- The action-id guard at its exact boundary: next_action == 2^31 is
    -- still accepted, the one after is refused.
    local S = new_session({ prefs = { rubber = "stroke" } })
    local page = J.replay({ J.encode({ k = "u", a = 2^31 - 1 }) }, base_cfg)
    report(page.next_action == 2^31, "guard setup: next_action is 2^31", num(page.next_action))
    S:open(0, page)
    S:run("set_ink_live", true)
    local got = S:ev((visit(0, "pen", { { 300, 300 } })))
    expect("the action guard's boundary: id 2^31 is still written", got,
           j("hold(on)", ARM, INK, "append(p0 s2147483648 pen) log fsync(p0) hold(off)"))
    got = S:ev((visit(100, "pen", { { 300, 400 } })))
    append_all(got, S:ev((visit(200, "rubber", { { 300, 300 }, { 300, 320 } }, 500))))
    expect("past it, ink and the stroke eraser are both refused, with one toast", got,
           "hold(on) toast hold(off) hold(on) hold(off)")
    got = S:ev(three(S.K, 1000, LEFT3, -400, 0, 5, 20))
    report(seq(got):match("^append%(p0 u2147483648%)") ~= nil,
           "past it, undo still works: it adds no action id", seq(got))

    -- A damaged line naming the codec's largest id: refused, never raised.
    local S2 = new_session()
    S2:open(0, J.replay({ '{"k":"s","a":9007199254740991,"tool"' }, base_cfg))
    S2:run("set_ink_live", true)
    local ok, out = pcall(S2.ev, S2, (visit(0, "pen", { { 300, 300 } })))
    expect("a page whose next action is 2^53: refused with a toast, no error",
           ok and out or {}, "hold(on) arm(0,0,1872,1404/0x00) toast hold(off)")
end

do
    -- The log's clock rules: realtime stepping back, and non-finite timings.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:run("note_timing", "stamp", 1 / 0)
    S:run("note_timing", "fsync", 0 / 0)
    S:run("note_timing", "publish", -5)
    S:ev(pen(10, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300)))
    S:ev(pen(5, "X", RX(320)))
    S:ev(pen(12, "TOUCH", 0))
    local line = S.log_lines[1]
    report(line:match(" dur=0us ") and line:match(" stamp=%- ")
           and line:match(" publish=1/0/0us ") and line:match(" fsync=%-$") ~= nil,
           "log: a backward step is 0 us; infinite and NaN timings are dropped, "
           .. "a negative one counts as 0", line)
    local rec = decode_last(S)
    report(rec.d[7] == 0, "the record clamps the same step", num(rec.d[7]))
    S:check("log clocks")
end

do
    -- io_error after close (the close's own fsync failed) is still final.
    local S = live_session()
    S:ev((visit(0, "pen", { { 300, 300 } })))
    S:run("close")
    local got = S:run("io_error", "EIO /data/notebooks")
    expect("io_error after close: log, disarm, toast; nothing to render", got,
           "log disarm toast")
    S:open(0)
    S:run("set_ink_live", true)
    got = S:ev((visit(1000, "pen", { { 300, 300 } })))
    expect("io_error lasts for the controller's life: a reopened notebook arms nothing",
           got, "hold(on) hold(off)")
    S:check("io_error after close")
end

------------------------------------------------------------------------
-- A write that fails, as the glue reports it (Session.fail_op)
------------------------------------------------------------------------

-- The region an append's record covers, from the command itself: the
-- failed line never reaches S.lines.
local function append_region(cmds)
    for _, c in ipairs(cmds) do
        if c.op == "append" then return rect(region_of(J.decode(c.line).bb)) end
    end
end

do
    -- The stroke's own append fails: the record comes back out of the
    -- page, and its ink is rendered away.
    local S = live_session()
    S:ev((visit(0, "pen", { { 300, 300 }, { 340, 300 } })))
    S:ev(hover_in(100, "pen", 500, 500))
    S.fail_op = "append"
    local got = S:ev((down(110, { { 500, 500 }, { 540, 500 } })))
    local R = append_region(got)
    expect("a stroke's append fails: the list runs, then io_error renders the stroke away",
           got, j(INK, INK, "append(p0 s2 pen) log log disarm toast",
                  "render(p0 1 " .. R .. ") repaint(" .. R .. ")"))
    report(#S.c.page.strokes == 1, "a stroke's append fails: the page in memory is as written",
           num(#S.c.page.strokes))
    got = S:ev(hover_out(200, "pen"))
    expect("a stroke's append fails: the earlier stroke still gets its fsync", got,
           "fsync(p0) hold(off)")
    S:check("failed stroke append")
end

do
    -- A stroke erase's append fails: io_error's render takes the erase
    -- back at once, and the leave's render agrees with it.
    local W1 = live_session()
    three_lines(W1, 0)
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    local RB = rect(region_of(S:replay(0).strokes[2].bb))
    S:ev(hover_in(1000, "pen", 900, 650))
    S.fail_op = "append"
    local got = S:ev((down(1010, { { 900, 650 }, { 900, 750 } })))
    expect("a stroke erase's append fails: the erased stroke is rendered back", got,
           j(WHITE, "append(p0 x4[2]) log log disarm toast render(p0 3 " .. RB .. ")",
             "repaint(" .. RB .. ")"))
    report(#S.c.page.strokes == 3, "the page in memory keeps all three strokes")
    got = S:ev(hover_out(1100, "pen"))
    expect("a failed erase: the leave's waiting render draws all three", got,
           "fsync(p0) disarm render(p0 3 " .. RB .. ") repaint(" .. RB .. ") hold(off)")
    S:check("failed erase append")
end

do
    -- An undo's append fails: the list's fsync still runs, then the
    -- undone stroke is rendered back.
    local S = live_session()
    S:ev((visit(0, "pen", { { 300, 300 }, { 340, 300 } })))
    S:ev((visit(100, "pen", { { 300, 600 }, { 340, 600 } })))
    local R = rect(region_of(J.decode(S.lines[0][2]).bb))
    S.fail_op = "append"
    local got = S:ev(three(S.K, 1000, LEFT3, -400, 0, 5, 20))
    expect("an undo's append fails: its render is taken back after the list", got,
           j("append(p0 u2) disarm render(p0 1 " .. R .. ") repaint(" .. R .. ") fsync(p0)",
             "log disarm toast render(p0 2 " .. R .. ") repaint(" .. R .. ")"))
    S:check("failed undo append")
end

do
    -- A tool switch whose report re-presses puts the rubber's first ink
    -- in the list after the tip's append.  When that append fails, the
    -- ink is skipped, and both strokes are rendered away.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev(pen(10, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300)))
    S:ev(pen(13, "X", RX(340)))
    S.fail_op = "append"
    local got = S:ev(pen(16, "TOUCH", 0, "PEN", 0, "RUBBER", 1, "TOUCH", 1, "P", 600,
                         "X", RX(400)))
    local toks = seq(got)
    report(toks:match("^append%(p0 s1 pen gap%) log log disarm toast render%(p0 0 [%d,]+%) "
                      .. "repaint%([%d,]+%)$") ~= nil and S.skipped == 2,
           "a failed append before same-list ink: the ink and its publish are skipped, "
           .. "the render covers both strokes", toks .. " skipped=" .. num(S.skipped))
    got = S:ev(pen(19, "X", RX(440)))
    append_all(got, S:ev(pen(22, "TOUCH", 0)))
    expect("the rubber's stroke was dropped with the failure: it inks no further", got, "")
    S:check("failed append before ink")
end

do
    -- A failed append followed, in the same list, by the page that
    -- loaded under the pen: the failed record belonged to the page left.
    local S = live_session()
    S:ev(finger(S.K, 0, 1400, 700, 900, 700, 5, 30))
    S:ev(hover_in(1000, "pen", 300, 300))
    local evs = down(1010, { { 300, 300 }, { 340, 300 } })
    S:ev(slice(evs, 1, 8))
    S:loaded(1)
    S.fail_op = "append"
    local got = S:ev(slice(evs, 9))
    expect("a failed append before a page change: nothing of page 0 is rendered over page 1",
           got, "append(p0 s1 pen) log disarm render(p1 0) repaint washer log disarm toast")
    S:check("failed append before a turn")
    S:ev(hover_out(1100, "pen"))
    S:ev(finger(S.K, 2000, 500, 700, 1000, 700, 5, 30))
    S:loaded(0)
    S:check("failed append, page 0 read back")
end

do
    -- An fsync fails: nothing is taken back, since what it syncs was
    -- written; ink stops.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev((down(10, { { 300, 300 } })))
    S.fail_op = "fsync"
    local got = S:ev(hover_out(100, "pen"))
    expect("an fsync fails at prox out: the list ends, then log, disarm, toast", got,
           "fsync(p0) hold(off) log disarm toast")
    got = S:ev((visit(200, "pen", { { 300, 500 } })))
    expect("after a failed fsync nothing arms or inks", got, "hold(on) hold(off)")
    S:check("failed fsync")
end

do
    -- close with a stroke in progress, and its append fails: close's
    -- sync, disarm and hold release all run before the report.  The
    -- fsync is nb:fsync's no-op for a page whose append failed.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev(pen(10, "TOUCH", 1, "P", 2000, "X", RX(300), "Y", RY(300)))
    S.fail_op = "append"
    local got = S:run("close")
    expect("close whose append fails: the rest of close runs, then the failure is logged",
           got, "append(p0 s1 pen gap) log fsync(p0) disarm hold(off) "
                .. "prefs(-,-,-,- last p=0) log disarm toast")
end

do
    -- An undo that reaches the controller with the pen in range (a
    -- same-batch drain) appends and repaints, but the sync waits.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev((down(10, { { 300, 300 }, { 400, 300 } })))
    local R = rect(region_of(J.decode(S.lines[0][1]).bb))
    local got = S:inject({ { k = "multi_swipe", dx = -600, dy = 0, fingers = 3,
                             t = ms(100) } })
    expect("undo with the pen in range: no fsync", got,
           "append(p0 u1) disarm render(p0 0 " .. R .. ") repaint(" .. R .. ")")
    got = S:ev(hover_out(200, "pen"))
    expect("then prox out syncs it", got, "fsync(p0) hold(off)")
    S:check("undo in range")
end

do
    -- Suspended, nothing arms: not a resync that finds the pen, not ink
    -- turning live.  Resume does.
    local S = live_session()
    S:run("set_ink_live", false)
    S:run("suspend")
    local got = S:run("resync", { prox = true, tool = "pen", touching = false }, ms(10))
    append_all(got, S:run("set_ink_live", true))
    expect("suspended: a resync into range and ink going live arm nothing", got, "hold(on)")
    NOW = ms(20)
    got = S:run("resume", { prox = true, tool = "pen", touching = false })
    expect("resume arms", got, ARM)
    S:check("suspended arm")
end

do
    -- The stroke eraser's reach at its edge, in all four directions: fine
    -- lines 13 px from the eraser's centre are inside eraser rmin 12 plus
    -- the line's 1.35 px radius, lines 14 px away are not.
    local W1 = live_session()
    local cx, cy = 900, 700
    local t = 0
    for _, dir in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        for _, d in ipairs({ 13, 14 }) do
            local pts
            if dir[1] ~= 0 then
                local x = cx + dir[1] * d
                pts = { { x, cy - 100 }, { x, cy + 100 } }
            else
                local y = cy + dir[2] * d
                pts = { { cx - 100, y }, { cx + 100, y } }
            end
            W1:ev((visit(t, "pen", pts)))
            t = t + 100
        end
    end
    local S = session_on(W1.lines[0], { prefs = { mode = "stroke_erase" } })
    S:ev((visit(2000, "pen", { { cx, cy } })))
    local rec = decode_last(S)
    local e = { { x = G.raw_to_px(RX(cx), XMAX, W), y = G.raw_to_px(RY(cy), YMAX, H) } }
    local R = Brush.style(Brush.IDS[1], "M", "eraser", base_cfg).rmin
    local want = {}
    for _, st in ipairs(W1:replay(0).strokes) do
        if Brush.hits(e, R, st.points, st.style, st.bb) then want[#want + 1] = st.a end
    end
    report(rec and rec.k == "x" and concat(rec.ids, ",") == "1,3,5,7"
           and concat(want, ",") == "1,3,5,7",
           "stroke erase at the reach's edge: left, right, above and below, 13 px in, "
           .. "14 px out", rec and rec.ids and concat(rec.ids, ",") or "-")
    S:check("stroke erase reach")
end

do
    -- Several pages written in one visit (turns injected under the
    -- hovering pen) are synced in page order at prox out.  pairs() gives
    -- these keys as 0, 2, -1.
    local S = live_session()
    S:ev(hover_in(0, "pen", 300, 300))
    S:ev((down(10, { { 300, 300 } })))
    S:inject({ { k = "swipe", dx = 600, dy = 0, t = ms(50) } })
    S:loaded(-1)
    S:ev((down(100, { { 300, 400 } })))
    for i = 1, 3 do S:inject({ { k = "swipe", dx = -600, dy = 0, t = ms(150 + i) } }) end
    S:loaded(2)
    S:ev((down(200, { { 300, 500 } })))
    local got = S:ev(hover_out(300, "pen"))
    expect("three pages written in one visit: synced in page order", got,
           "fsync(p-1) fsync(p0) fsync(p2) hold(off)")
    S:check("fsync order")
end

do
    -- io_error with the panel open: Undo and Redo go dead on the panel.
    local S = live_session()
    S:ev((visit(0, "pen", { { 300, 300 } })))
    S:long_press(1000, 900, 700)
    local pos = seq({ { op = "panel", layout = S.layout } })
    local got = S:run("io_error", "ENOSPC /data/notebooks")
    expect("io_error with the panel open: the panel re-laid out", got,
           j("log disarm toast", pos))
    local by = {}
    for _, it in ipairs(S.layout.items) do by[it.id] = it end
    report(not by.undo.enabled and not by.redo.enabled,
           "io_error with the panel open: Undo and Redo disabled")
    S:check("io_error with the panel")
end

do
    -- Page numbers stop at 2^52 either way, so they stay exact integers.
    local S = new_session()
    S:open(2^52)
    local got = S:ev(finger(S.K, 0, 1400, 700, 900, 700, 5, 30))
    append_all(got, S:ev(finger(S.K, 1000, 500, 700, 1000, 700, 5, 30)))
    expect("page 2^52: no next page, the previous one loads", got,
           "disarm load(p4503599627370495)")
    S = new_session()
    S:open(-2^52)
    got = S:ev(finger(S.K, 0, 500, 700, 1000, 700, 5, 30))
    expect("page -2^52: no previous page", got, "")
end

do
    -- The record keeps the rotation the stroke began in.
    local S = live_session({ mode = 0 })
    S:ev(hover_in(0, "pen", 300, 300))
    local evs = down(10, { { 300, 300 }, { 330, 300 }, { 360, 300 } })
    S:ev(slice(evs, 1, 8))
    S:run("set_rotation", 1)
    S:ev(slice(evs, 9))
    local rec = decode_last(S)
    report(rec.rot == 0 and rec.gap == 0, "a rotation mid-stroke: the record keeps mode 0",
           num(rec.rot))
    S:check("rotation mid-stroke")
end

------------------------------------------------------------------------
-- Real captures
------------------------------------------------------------------------

ffi.cdef [[
typedef struct {
    int64_t sec; int64_t usec; uint16_t type; uint16_t code; int32_t value;
} nbctl_input_event;
]]

local function load_events(path)
    local f = io.open(path, "rb")
    local data = f:read("*a")
    f:close()
    local n = floor(#data / 24)
    local recs = ffi.cast("const nbctl_input_event *", data)
    local evs = {}
    local touches, tools = 0, {}
    local pen_down, rub_down, recent = false, false, nil
    for i = 0, n - 1 do
        local e = recs[i]
        local ty, code, v = e.type, e.code, e.value
        local ev = { src = "pen", type = ty, code = code, value = v,
                     t = tonumber(e.sec) * 1000000 + tonumber(e.usec) }
        -- The captures hold digitizer units; device.lua would pass them
        -- as raw with the rounded px as value.
        if ty == 3 and code <= 1 then
            ev.raw = v
            local npx, max = W, XMAX
            if code == 1 then npx, max = H, YMAX end
            ev.value = floor(v * npx / max + 0.5)
        end
        if ty == 1 and code == 320 then
            pen_down = v ~= 0
            if v ~= 0 then recent = "pen" end
        elseif ty == 1 and code == 321 then
            rub_down = v ~= 0
            if v ~= 0 then recent = "rubber" end
        elseif ty == 1 and code == 330 and v == 1 then
            touches = touches + 1
            tools[touches] = (rub_down and (not pen_down or recent == "rubber"))
                             and "eraser" or "pen"
        end
        evs[#evs + 1] = ev
    end
    return evs, touches, tools
end

local captures = {
    { name = "pen-1.bin", touches = 156, rubber = 2 },
    { name = "pen-3.bin", touches = 86, rubber = 7 },
}
local present = true
for _, c in ipairs(captures) do
    local f = io.open(capture_dir .. "/" .. c.name, "rb")
    if f then f:close() else present = false end
end
if not present then
    print("PASS: real-capture replay skipped (absent)")
else
    for _, c in ipairs(captures) do
        local evs, touches, tools = load_events(capture_dir .. "/" .. c.name)
        local S = live_session({ prefs = { brush = "ballpoint" }, lat = 1000 })
        S:ev(evs)
        local lines = S.lines[0] or {}
        local page = J.replay(lines, base_cfg)
        local bad, erasers, mismatch = 0, 0, 0
        for i, line in ipairs(lines) do
            local rec = J.decode(line)
            if not rec or rec.k ~= "s" then
                bad = bad + 1
            else
                if rec.tool == "eraser" then
                    erasers = erasers + 1
                    if rec.comp ~= "white" or rec.st[4] ~= base_cfg.rubber_p_lo
                       or rec.st[5] ~= base_cfg.rubber_p_hi then
                        mismatch = mismatch + 1
                    end
                end
                if rec.tool ~= tools[i] then mismatch = mismatch + 1 end
            end
        end
        report(touches == c.touches and #lines == touches and #page.strokes == touches
               and page.bad_lines == 0 and bad == 0,
               c.name .. ": one decodable stroke record per BTN_TOUCH:1, all replayed",
               format("%d BTN_TOUCH:1, %d appends, %d replayed strokes", touches, #lines,
                      #page.strokes))
        report(erasers == c.rubber and mismatch == 0,
               c.name .. ": rubber strokes are eraser records, in capture order",
               format("%d eraser records", erasers))
        report(S.logs == #lines, c.name .. ": one log line per pen-up",
               format("%d log lines", S.logs))
        S:check(c.name)

        -- The controller's own cost: no harness around it.
        local cc = Ctl.new{ cfg = base_cfg, prefs = { brush = "ballpoint" },
                            now_rt_us = now }
        cc:open(NB, 0, J.replay({}, base_cfg))
        cc:set_ink_live(true)
        local inks = 0
        local t_start = os.clock()
        for _, e in ipairs(evs) do
            NOW = e.t + 1000
            local out = cc:feed(e)
            for i = 1, #out do
                if out[i].op == "ink" then inks = inks + 1 end
            end
        end
        local dt = os.clock() - t_start
        io.stderr:write(format("BENCH: %s: %d events in %.1f ms: %.2f us/event; "
                               .. "%d inked samples, %.1f us each if all cost were "
                               .. "theirs\n", c.name, #evs, dt * 1e3,
                               dt * 1e6 / #evs, inks, dt * 1e6 / math.max(1, inks)))
    end
end

if fail == 0 then
    print("RESULT: ok")
else
    print(format("RESULT: failed (%d)", fail))
    os.exit(1)
end
