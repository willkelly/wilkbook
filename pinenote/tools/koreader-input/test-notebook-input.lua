--[[--
Host harness for the notebook's input recognizer (notebook.koplugin
nb_input.lua).

The module is pure, so this runs it table-driven under the koreader-bin
bundle's luajit: synthetic w9013 Stylus reports and cyttsp5 frames, built
in kernel event order, go through Input:feed / on_timer / resync /
set_touch_slot, and every intent that comes back is compared as one
canonical string per intent.  The touch builder behaves like the input
core: it emits ABS_MT_SLOT only when the slot changes and an axis only
when its value changes, so per-slot latching is exercised the way the
device exercises it.

Pen: axis latching and carry, commit at SYN_REPORT, BTN_TOUCH gating
(the rubber's pressure at distance 0), tool switch and proximity loss
mid-contact, SYN_DROPPED discard + resync, the pen-4 open-mid-stroke
case, the raw-unit fallback, penbtn swallowing, activity rate limiting
with hover never counting.

Touch: tap (canvas, panel), long press by timer and by a late lift,
swipe with its time/length/ratio limits, two-finger swipes (and a
finger that stays still beside a swiping one), multi-finger swipes whose
contacts drop out and reappear (peak 3, 4, 5), panel drag and flick
velocity, palm rejection at start (grace boundary, a batch drained out
of time order), the veto for a palm that landed before the pen,
touch_down_changed, touch SYN_DROPPED, set_touch_slot.

Boundaries and unusual orders: every threshold at its exact value and
one unit past it, BTN_TOUCH ahead of the tool key, both tool keys down,
a BTN_TOUCH:1 cut off by SYN_DROPPED, a snapshot that changes the tool,
the pen opened while hovering (pen-5's shape), stale timers, a flick
across a realtime step, a palm under a multi-finger swipe, and the
physical-to-logical swipe sign the controller relies on.

Then a replay of the operator's 2026-09-26 Stylus captures (pen-1.bin
and pen-3.bin, 24-byte aarch64 input_event records).  They are
gitignored and absent in CI, so that part SKIPs with one fixed PASS
line when either file is missing.  The captures carry no raw_value, so
X/Y values are fed as raw digitizer units.

Usage: luajit test-notebook-input.lua <koreader_dir> <plugin_dir> [capture_dir]
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")
local script_dir = arg[0]:match("^(.*)/[^/]*$") or "."
local capture_dir = arg[3] or (script_dir .. "/../pen/build/captures-20260926")
local _ = koreader_dir -- nb_input is pure: the bundle supplies only luajit

package.path = plugin_dir .. "/?.lua;" .. package.path

local ffi = require("ffi")
local Input = require("nb_input")
local base_cfg = dofile(plugin_dir .. "/nb_config.lua")

local fail = 0
local function report(ok, label, msg)
    if msg then
        print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    else
        print(string.format("%s: %s", ok and "PASS" or "FAIL", label))
    end
    if not ok then fail = fail + 1 end
end

local function config(over)
    local c = {}
    for k, v in pairs(base_cfg) do c[k] = v end
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local W, H = base_cfg.W, base_cfg.H
local XMAX, YMAX = base_cfg.abs_x_max, base_cfg.abs_y_max
local function PX(raw) return raw * (W - 1) / XMAX end
local function PY(raw) return raw * (H - 1) / YMAX end

-- The controller's hit test, standing in for an open panel at physical
-- x 1200..1599, y 100..499.
local function hit(x, y)
    if x >= 1200 and x < 1600 and y >= 100 and y < 500 then return "panel" end
    return "canvas"
end

-- Realtime microseconds; printed relative to T0.
local T0 = 1758844800 * 1000000
local function ms(n) return T0 + n * 1000 end

------------------------------------------------------------------------
-- Event builders
------------------------------------------------------------------------

local CODE = {
    PEN = { 1, 320 }, RUBBER = { 1, 321 }, TOUCH = { 1, 330 },
    STYLUS = { 1, 331 }, STYLUS2 = { 1, 332 },
    X = { 3, 0 }, Y = { 3, 1 }, P = { 3, 24 }, D = { 3, 25 },
    TX = { 3, 26 }, TY = { 3, 27 }, SCAN = { 4, 4 },
    SLOT = { 3, 47 }, MAJ = { 3, 48 }, MX = { 3, 53 }, MY = { 3, 54 },
    ID = { 3, 57 }, MP = { 3, 58 },
}

-- Events without the closing SYN_REPORT.
local function bare(src, t, list)
    local out = {}
    for i = 1, #list, 2 do
        local name, v = list[i], list[i + 1]
        local tc = CODE[name]
        local ev = { src = src, t = t, type = tc[1], code = tc[2], value = v }
        if src == "pen" and (name == "X" or name == "Y") then
            -- device.lua's helper: rounded px as value, digitizer unit as raw
            local n, max = W, XMAX
            if name == "Y" then n, max = H, YMAX end
            ev.raw = v
            ev.value = math.floor(v * n / max + 0.5)
        end
        out[#out + 1] = ev
    end
    return out
end

local function syn(src, t)
    return { { src = src, t = t, type = 0, code = 0, value = 0 } }
end

local function frame(src, t, list)
    local out = bare(src, t, list)
    out[#out + 1] = syn(src, t)[1]
    return out
end

local function pen(t_ms, ...) return frame("pen", ms(t_ms), { ... }) end
local function touch(t_ms, ...) return frame("touch", ms(t_ms), { ... }) end
local function drop(src, t_ms)
    return { { src = src, t = ms(t_ms), type = 0, code = 3, value = 0 } }
end
local function timer(t_ms) return { { timer = ms(t_ms) } } end
local function resync(snap, t_ms) return { { resync = snap, now = ms(t_ms) } } end

-- A cyttsp5 as the input core presents it.  acts: { {slot, id=, x=, y=} }
-- in record order, lifts last (input_mt_sync_frame's auto-lift).
local function kernel(slot0)
    local K = { slot = slot0 or 0, x = {}, y = {} }
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

local function steps(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, s in ipairs(list) do out[#out + 1] = s end
    end
    return out
end

local function play(inp, list)
    local got = {}
    for _, s in ipairs(list) do
        local r
        if s.timer then
            r = inp:on_timer(s.timer)
        elseif s.resync then
            r = inp:resync(s.resync, s.now)
        else
            assert(s.src, "test step is not an event, timer or resync")
            r = inp:feed(s)
        end
        for _, it in ipairs(r) do got[#got + 1] = it end
    end
    return got
end

------------------------------------------------------------------------
-- Canonical intent strings
------------------------------------------------------------------------

local FIELDS = { "on", "tool", "target", "t", "x", "y", "p", "tx", "ty",
                 "rawx", "rawy", "dx", "dy", "vx", "vy", "fingers", "gap",
                 "any_down", "delay_us" }

local function num(v)
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.3f", v)
end

local function fmt(it)
    local parts = { it.k }
    local known = { k = true }
    for _, f in ipairs(FIELDS) do
        known[f] = true
        local v = it[f]
        if v ~= nil then
            if f == "t" then v = v - T0 end
            parts[#parts + 1] = f .. "=" .. (type(v) == "number" and num(v) or tostring(v))
        end
    end
    -- Fields outside the contract, sorted, so a stray one fails the
    -- comparison the same way on every run.
    local extra = {}
    for key in pairs(it) do
        if not known[key] then extra[#extra + 1] = tostring(key) end
    end
    table.sort(extra)
    for _, key in ipairs(extra) do
        parts[#parts + 1] = key .. "=" .. tostring(it[key])
    end
    return table.concat(parts, " ")
end

local function expect(label, got, want)
    local g, w = {}, {}
    for i, it in ipairs(got) do g[i] = fmt(it) end
    for i, it in ipairs(want) do w[i] = fmt(it) end
    local gs, ws = table.concat(g, " | "), table.concat(w, " | ")
    if gs == ws then
        report(true, label)
    else
        report(false, label, "\n  got:  " .. gs .. "\n  want: " .. ws)
    end
end

-- Expected-intent constructors.
local function prox(on, tool, t_ms)
    return { k = "prox", on = on, tool = tool, t = ms(t_ms) }
end
local function sample(k, t_ms, rx, ry, p, tx, ty)
    return { k = k, t = ms(t_ms), x = PX(rx), y = PY(ry), p = p,
             tx = tx or 0, ty = ty or 0, rawx = rx, rawy = ry }
end
local function begin(tool, t_ms, rx, ry, p, tx, ty)
    local s = sample("stroke_begin", t_ms, rx, ry, p, tx, ty)
    s.tool = tool
    return s
end
local function point(t_ms, rx, ry, p, tx, ty)
    return sample("stroke_point", t_ms, rx, ry, p, tx, ty)
end
local function sEnd(t_ms, gap) return { k = "stroke_end", t = ms(t_ms), gap = gap } end
local function act(t_ms) return { k = "activity", t = ms(t_ms) } end
local function tdc(down) return { k = "touch_down_changed", any_down = down } end
local function tmr(us) return { k = "timer", delay_us = us } end
local function tap(x, y, t_ms, target)
    return { k = "tap", x = x, y = y, t = ms(t_ms), target = target }
end
local function lp(x, y, t_ms) return { k = "long_press", x = x, y = y, t = ms(t_ms) } end
local function swipe(dx, dy, t_ms)
    return { k = "swipe", dx = dx, dy = dy, t = ms(t_ms) }
end
local function mswipe(dx, dy, fingers, t_ms)
    return { k = "multi_swipe", dx = dx, dy = dy, fingers = fingers, t = ms(t_ms) }
end
local function dBegin(x, y, t_ms)
    return { k = "drag_begin", x = x, y = y, t = ms(t_ms) }
end
local function dMove(x, y, t_ms)
    return { k = "drag_move", x = x, y = y, t = ms(t_ms) }
end
local function dEnd(x, y, t_ms, vx, vy)
    return { k = "drag_end", x = x, y = y, t = ms(t_ms), vx = vx, vy = vy }
end
local PEN_RESYNC = { k = "pen_resync" }

local function new() return Input.new(config(), hit) end

------------------------------------------------------------------------
-- Pen
------------------------------------------------------------------------

do
    local inp = new()
    local got = play(inp, pen(0, "PEN", 1, "X", 5000, "Y", 4000, "D", -80))
    local in_range = inp:pen_in_range()
    got = steps(got, play(inp, steps(
        pen(3, "X", 5010, "D", -40),
        -- the pen-down report: BTN_TOUCH:1 before its new X/Y
        pen(6, "SCAN", 852034, "TOUCH", 1, "P", 900, "X", 5020, "Y", 4010),
        pen(9, "SCAN", 852034, "X", 5030),
        pen(12, "SCAN", 852034, "P", 1200, "TX", 1500),
        pen(15, "SCAN", 852034, "Y", 4030, "TY", -700),
        -- the lift report's X is hover travel, not ink
        pen(18, "SCAN", 852034, "TOUCH", 0, "P", 0, "X", 5100),
        pen(21, "X", 5200),
        pen(24, "PEN", 0))))
    expect("pen: axes latch on their events, commit at SYN_REPORT, carry across reports",
           got, {
        prox(true, "pen", 0),
        begin("pen", 6, 5020, 4010, 900),
        act(6),
        point(9, 5030, 4010, 900),
        point(12, 5030, 4010, 1200, 1500, 0),
        point(15, 5030, 4030, 1200, 1500, -700),
        sEnd(18, false),
        prox(false, "pen", 24),
    })
    report(in_range and not inp:pen_in_range(),
           "pen: pen_in_range follows committed proximity")
end

do
    -- device.lua's value is ignored when raw is present; without raw the
    -- px scale is inverted so rawx/rawy stay digitizer units.
    local function rawev(t_ms, code, value, raw)
        return { src = "pen", t = ms(t_ms), type = 3, code = code, value = value,
                 raw = raw }
    end
    local inp = new()
    local list = steps(pen(0, "PEN", 1, "X", 100, "Y", 100), pen(3, "TOUCH", 1, "P", 1000))
    local cases = {
        { 20966, 15725 }, { 0, 0 }, { 10483, 7000 }, { 21500, 16000 }, { -40, -9 },
    }
    for i, c in ipairs(cases) do
        list = steps(list, { rawev(3 + 3 * i, 0, -5, c[1]), rawev(3 + 3 * i, 1, -5, c[2]) },
                     syn("pen", ms(3 + 3 * i)))
    end
    local got = play(inp, list)
    local xs = {}
    for _, it in ipairs(got) do
        if it.k == "stroke_point" then
            xs[#xs + 1] = string.format("(%s,%s raw %s,%s)", num(it.x), num(it.y),
                                        num(it.rawx), num(it.rawy))
        end
    end
    local want = "(1871,1403 raw 20966,15725) (0,0 raw 0,0)"
        .. " (935.500,624.547 raw 10483,7000)"
        .. " (1871,1403 raw 21500,16000) (0,0 raw -40,-9)"
    report(table.concat(xs, " ") == want,
           "pen: raw drives px: 20966->1871, 15725->1403, clamped at both ends",
           table.concat(xs, " "))

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 100, "Y", 100),
        pen(3, "TOUCH", 1, "P", 1000),
        { rawev(6, 0, 1871, nil), rawev(6, 1, 1403, nil) }, syn("pen", ms(6)),
        { rawev(9, 0, 935, nil) }, syn("pen", ms(9))))
    local a, b = got[#got - 1], got[#got]
    report(a.rawx == XMAX and a.rawy == YMAX and a.x == W - 1 and a.y == H - 1
           and math.abs(b.x - 935) < 1e-9,
           "pen: without ev.raw the px value is scaled back to raw units",
           string.format("rawx=%s rawy=%s x=%s", num(a.rawx), num(a.rawy), num(b.x)))

    -- Contact before any X/Y has been seen since open: there is no
    -- position to start from, so that contact is lost, not guessed.
    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1),
        pen(3, "TOUCH", 1, "P", 1000),
        pen(6, "X", 4000, "Y", 4000),
        pen(9, "TOUCH", 0),
        pen(12, "TOUCH", 1)))
    expect("pen: no stroke before a position is latched; the next contact inks", got, {
        prox(true, "pen", 0),
        begin("pen", 12, 4000, 4000, 1000),
        act(12),
    })
end

do
    local inp = new()
    local got = play(inp, steps(
        pen(0, "RUBBER", 1, "X", 8000, "Y", 6000, "D", -60),
        -- the rubber at distance 0 reports pressure without contact
        pen(3, "D", 0, "P", 250),
        pen(6, "P", 318, "X", 8010),
        pen(9, "P", 180),
        pen(12, "TOUCH", 1, "P", 600, "X", 8020),
        pen(15, "TOUCH", 0, "P", 0),
        pen(18, "RUBBER", 0)))
    expect("pen: pressure without BTN_TOUCH never inks (rubber at distance 0)", got, {
        prox(true, "rubber", 0),
        begin("rubber", 12, 8020, 6000, 600),
        act(12),
        sEnd(15, false),
        prox(false, "rubber", 18),
    })

    inp = new()
    got = play(inp, steps(
        pen(0, "TOUCH", 1, "P", 900, "X", 5000, "Y", 5000), -- no tool: not in range
        pen(3, "X", 5010),
        pen(6, "PEN", 1),        -- in range with BTN_TOUCH already latched
        pen(9, "X", 5020),
        pen(12, "TOUCH", 0),
        pen(15, "TOUCH", 1, "X", 5030)))
    expect("pen: a stroke begins only in a report carrying BTN_TOUCH:1 in range",
           got, {
        prox(true, "pen", 6),
        begin("pen", 15, 5030, 5000, 900),
        act(15),
    })
end

do
    local inp = new()
    local got = play(inp, steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        pen(3, "TOUCH", 1, "P", 1000),
        pen(6, "X", 5010),
        pen(9, "PEN", 0, "RUBBER", 1, "P", 400), -- switch with BTN_TOUCH still 1
        pen(12, "X", 5020),
        pen(15, "TOUCH", 0),
        pen(18, "TOUCH", 1, "P", 500)))
    expect("pen: tool switch mid-contact ends with gap; the new tool needs BTN_TOUCH:1",
           got, {
        prox(true, "pen", 0),
        begin("pen", 3, 5000, 5000, 1000),
        act(3),
        point(6, 5010, 5000, 1000),
        sEnd(9, true),
        prox(false, "pen", 9),
        prox(true, "rubber", 9),
        begin("rubber", 18, 5020, 5000, 500),
    })

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        pen(3, "TOUCH", 1, "P", 1000),
        pen(6, "TOUCH", 0, "PEN", 0, "P", 0), -- the kernel's own tool-change frame
        pen(9, "RUBBER", 1, "X", 5100, "D", -30),
        pen(12, "TOUCH", 1, "P", 700),
        pen(15, "TOUCH", 0, "P", 0)))
    expect("pen: pen->rubber through a tool-less report (kernel framing)", got, {
        prox(true, "pen", 0),
        begin("pen", 3, 5000, 5000, 1000),
        act(3),
        sEnd(6, true),
        prox(false, "pen", 6),
        prox(true, "rubber", 9),
        begin("rubber", 12, 5100, 5000, 700),
        sEnd(15, false),
    })
end

do
    local inp = new()
    local got = play(inp, steps(
        pen(0, "PEN", 1, "X", 9000, "Y", 300),
        pen(3, "TOUCH", 1, "P", 3000),
        pen(6, "Y", 100),
        pen(9, "TOUCH", 0, "P", 0, "PEN", 0), -- pen-1's Y=0 edge dropout
        -- back 30 ms later, at full pressure
        pen(39, "TOUCH", 1, "P", 4095, "PEN", 1, "X", 9400, "Y", 50),
        pen(42, "Y", 60),
        pen(45, "TOUCH", 0, "P", 0)))
    expect("pen: proximity dropout mid-contact is two strokes, never a chord", got, {
        prox(true, "pen", 0),
        begin("pen", 3, 9000, 300, 3000),
        act(3),
        point(6, 9000, 100, 3000),
        sEnd(9, true),
        prox(false, "pen", 9),
        prox(true, "pen", 39),
        begin("pen", 39, 9400, 50, 4095),
        point(42, 9400, 60, 4095),
        sEnd(45, false),
    })

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 9000, "Y", 5000),
        pen(3, "TOUCH", 1, "P", 3000),
        pen(6, "PEN", 0),              -- tool lost, BTN_TOUCH never released
        pen(9, "PEN", 1, "X", 9100),   -- back without a BTN_TOUCH:1
        pen(12, "X", 9200),
        pen(15, "TOUCH", 0),
        pen(18, "TOUCH", 1)))
    expect("pen: BTN_TOOL_PEN:0 alone mid-contact ends with gap; return needs BTN_TOUCH:1",
           got, {
        prox(true, "pen", 0),
        begin("pen", 3, 9000, 5000, 3000),
        act(3),
        sEnd(6, true),
        prox(false, "pen", 6),
        prox(true, "pen", 9),
        begin("pen", 18, 9200, 5000, 3000),
    })
end

do
    local inp = new()
    local got = play(inp, steps(
        pen(0, "PEN", 1, "X", 6000, "Y", 5000),
        pen(3, "TOUCH", 1, "P", 2000),
        pen(6, "X", 6010),
        drop("pen", 9),
        bare("pen", ms(9), { "X", 9999, "TOUCH", 0 }), -- the cut report's tail
        syn("pen", ms(9)),
        pen(12, "Y", 5100),           -- still latched down: no fresh BTN_TOUCH:1
        resync({ prox = true, tool = "pen", touching = true }, 14),
        pen(15, "Y", 5110),
        pen(18, "TOUCH", 0, "P", 0),
        pen(21, "TOUCH", 1, "P", 2500)))
    expect("pen: SYN_DROPPED ends the stroke, discards, resyncs, waits for BTN_TOUCH:1",
           got, {
        prox(true, "pen", 0),
        begin("pen", 3, 6000, 5000, 2000),
        act(3),
        point(6, 6010, 5000, 2000),
        sEnd(9, true),
        PEN_RESYNC,
        begin("pen", 21, 6010, 5110, 2500),
    })

    got = play(inp, steps(
        pen(24, "TOUCH", 0, "P", 0),
        drop("pen", 30),              -- hovering: nothing to end
        syn("pen", ms(30)),
        resync({ prox = true, tool = "rubber", touching = false }, 33),
        resync({ prox = false }, 36)))
    expect("pen: SYN_DROPPED while hovering; the snapshot sets proximity and tool", got, {
        sEnd(24, false),
        PEN_RESYNC,
        prox(false, "pen", 33),
        prox(true, "rubber", 33),
        prox(false, "rubber", 36),
    })
    report(not inp:pen_in_range(), "pen: out of range after a prox=false snapshot")

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 6000, "Y", 5000),
        pen(3, "TOUCH", 1, "P", 2000),
        resync({ prox = true, tool = "pen", touching = true }, 5),
        pen(6, "X", 6100)))
    expect("pen: a resync mid-stroke ends it with gap (never joined across)", got, {
        prox(true, "pen", 0),
        begin("pen", 3, 6000, 5000, 2000),
        act(3),
        sEnd(5, true),
    })
end

do
    -- pen-4 opens mid-stroke: 53 reports of P/X/Y with no tool or touch key.
    local inp = new()
    local got = play(inp, steps(
        resync({ prox = true, tool = "pen", touching = true }, 0),
        pen(3, "P", 2000, "X", 7000, "Y", 7000),
        pen(6, "P", 2100, "X", 7010),
        pen(9, "TOUCH", 0, "P", 0),
        pen(12, "TOUCH", 1, "P", 800, "X", 7100)))
    expect("pen: open mid-stroke: the snapshot gives proximity, ink waits for BTN_TOUCH:1",
           got, {
        prox(true, "pen", 0),
        begin("pen", 12, 7100, 7000, 800),
        act(12),
    })

    inp = new()
    got = play(inp, steps(
        pen(3, "P", 2000, "X", 7000, "Y", 7000),
        pen(9, "TOUCH", 0, "P", 0),
        pen(12, "TOUCH", 1, "P", 800, "X", 7100),
        pen(15, "TOUCH", 0)))
    expect("pen: open mid-stroke without a snapshot stays inert", got, {})

    -- pen-5 opens with the pen hovering: its first BTN_TOOL_* event is a
    -- PEN:0, and without a snapshot at open its first 3 of 58 contacts
    -- are lost, and a palm under the unseen pen counts as a finger.
    local function hovering()
        return steps(
            pen(0, "X", 7000, "Y", 7000, "D", -40),
            pen(3, "TOUCH", 1, "P", 900, "X", 7010),
            touch(4, "ID", 130, "MX", 300, "MY", 1200),
            pen(6, "X", 7020),
            pen(9, "TOUCH", 0, "P", 0))
    end
    expect("pen: opened while hovering, no snapshot: no ink, and a palm is accepted",
           play(new(), hovering()), { tmr(700000), act(4), tdc(true) })
    inp = new()
    got = play(inp, steps(resync({ prox = true, tool = "pen", touching = false }, -1),
                          hovering()))
    expect("pen: opened while hovering, snapshot at open: ink and palm rejection", got, {
        prox(true, "pen", -1),
        begin("pen", 3, 7010, 7000, 900),
        act(3),
        tdc(true),
        point(6, 7020, 7000, 900),
        sEnd(9, false),
    })
end

do
    local inp = new()
    local r1 = inp:feed({ src = "penbtn", t = ms(0), type = 1, code = 142, value = 1 })
    local r2 = inp:feed({ src = "penbtn", t = ms(0), type = 0, code = 0, value = 0 })
    local ok_ro = not pcall(function() Input.NONE[1] = 1 end)
    report(rawequal(r1, Input.NONE) and rawequal(r2, Input.NONE) and #r1 == 0 and ok_ro,
           "penbtn: ws8100 events are swallowed with no intents (shared read-only NONE)")

    local got = play(inp, steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        pen(3, "TOUCH", 1, "P", 1000),
        pen(6, "STYLUS", 1),
        pen(9, "STYLUS2", 1, "X", 5010),
        pen(12, "STYLUS", 0, "STYLUS2", 0),
        pen(15, "TOUCH", 0)))
    expect("pen: barrel buttons neither end nor start strokes", got, {
        prox(true, "pen", 0),
        begin("pen", 3, 5000, 5000, 1000),
        act(3),
        point(6, 5000, 5000, 1000),
        point(9, 5010, 5000, 1000),
        point(12, 5010, 5000, 1000),
        sEnd(15, false),
    })

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "TOUCH", 1, "P", 4095, "X", 3000, "Y", 3000),
        pen(3, "TOUCH", 0, "P", 0),
        pen(6, "PEN", 0)))
    expect("pen: proximity and contact in one report; a one-report stroke is begin+end",
           got, {
        prox(true, "pen", 0),
        begin("pen", 0, 3000, 3000, 4095),
        act(0),
        sEnd(3, false),
        prox(false, "pen", 6),
    })
end

do
    local inp = new()
    local list = steps(pen(0, "PEN", 1, "X", 5000, "Y", 5000),
                       pen(3, "TOUCH", 1, "P", 1000))
    for t = 6, 1200, 3 do list = steps(list, pen(t, "X", 5000 + t)) end
    list = steps(list, pen(1203, "TOUCH", 0))
    for t = 1206, 4197, 3 do list = steps(list, pen(t, "X", 5000 + t % 100)) end
    list = steps(list,
        pen(4200, "TOUCH", 1), pen(4203, "TOUCH", 0),
        pen(4500, "TOUCH", 1), pen(4503, "TOUCH", 0),
        pen(4506 - 3600000, "TOUCH", 1)) -- realtime stepped back an hour
    local ts = {}
    for _, it in ipairs(play(inp, list)) do
        if it.k == "activity" then ts[#ts + 1] = num((it.t - T0) / 1000) end
    end
    local s = table.concat(ts, ",")
    report(s == "3,1005,4200,-3595494",
           "activity: rate-limited while down, none in hover, re-based on a clock step",
           "ms " .. s)

    inp = new()
    list = pen(0, "PEN", 1, "X", 5000, "Y", 5000)
    for t = 3, 6000, 3 do list = steps(list, pen(t, "X", 5000 + t % 200, "D", -50)) end
    local got = play(inp, list)
    report(#got == 1 and got[1].k == "prox", "activity: 6 s of hover produces none",
           #got .. " intent(s)")
end

------------------------------------------------------------------------
-- Touch
------------------------------------------------------------------------

do
    local inp = new()
    local got = play(inp, touch(0, "ID", 100, "MX", 500, "MY", 700))
    local down = inp:any_touch_down()
    got = steps(got, play(inp, steps(touch(50, "MX", 505), touch(120, "ID", -1))))
    expect("touch: canvas tap (arms the long-press timer at contact start)", got, {
        tmr(700000), act(0), tdc(true),
        tap(500, 700, 120, "canvas"), tdc(false),
    })
    report(down and not inp:any_touch_down(),
           "touch: any_touch_down follows committed contacts")

    inp = new()
    got = play(inp, steps(touch(0, "ID", 101, "MX", 1300, "MY", 200), touch(100, "ID", -1)))
    expect("touch: panel tap (no long press on the panel)", got, {
        act(0), tdc(true), tap(1300, 200, 100, "panel"), tdc(false),
    })

    inp = new()
    got = play(inp, steps(touch(0, "ID", 102, "MX", 500, "MY", 700), touch(500, "ID", -1)))
    expect("touch: a 500 ms still press is neither tap nor long press", got, {
        tmr(700000), act(0), tdc(true), tdc(false),
    })

    inp = new()
    got = play(inp, steps(touch(0, "ID", 103, "MX", 500, "MY", 700),
                          touch(50, "MX", 530), touch(100, "ID", -1)))
    expect("touch: 30 px of travel is outside the tap slop and short of a swipe", got, {
        tmr(700000), act(0), tdc(true), tdc(false),
    })
end

do
    local inp = new()
    local got = play(inp, steps(
        touch(0, "ID", 110, "MX", 600, "MY", 600),
        timer(300),                -- early: re-arm for the rest
        touch(400, "MX", 610),     -- inside the slop
        timer(700),
        touch(900, "MX", 700),     -- after it fired the contact produces nothing
        touch(950, "ID", -1)))
    expect("long press: on_timer fires it, re-arms when early, and the contact is spent",
           got, {
        tmr(700000), act(0), tdc(true),
        tmr(400000),
        lp(610, 600, 700),
        tdc(false),
    })

    inp = new()
    got = play(inp, steps(
        touch(0, "ID", 111, "MX", 600, "MY", 600),
        touch(200, "MX", 640),
        timer(700),
        touch(750, "ID", -1)))
    expect("long press: travel past longpress_slop_px cancels it", got, {
        tmr(700000), act(0), tdc(true), tdc(false),
    })

    inp = new()
    got = play(inp, steps(
        touch(0, "ID", 112, "MX", 600, "MY", 600),
        touch(800, "ID", -1),      -- the UI loop never ran the timer
        timer(900)))
    expect("long press: a late timer is covered by the lift's event times", got, {
        tmr(700000), act(0), tdc(true),
        lp(600, 600, 800), tdc(false),
    })
end

do
    -- One contact from (x0,y0) to (x1,y1) in n equal frames dt_ms apart,
    -- lifting 10 ms after the last.
    local function stroke(id, x0, y0, x1, y1, n, dt_ms)
        local list = touch(0, "ID", id, "MX", x0, "MY", y0)
        for i = 1, n do
            local x = x0 + math.floor((x1 - x0) * i / n + 0.5)
            local y = y0 + math.floor((y1 - y0) * i / n + 0.5)
            list = steps(list, touch(i * dt_ms, "MX", x, "MY", y))
        end
        return steps(list, touch(n * dt_ms + 10, "ID", -1))
    end
    local head = { tmr(700000), act(0), tdc(true) }
    local function with(tail)
        local t = { head[1], head[2], head[3] }
        for _, it in ipairs(tail) do t[#t + 1] = it end
        return t
    end
    expect("swipe: leftward, 600 px in 310 ms",
           play(new(), stroke(120, 1000, 700, 400, 705, 10, 30)),
           with({ swipe(-600, 5, 310), tdc(false) }))
    expect("swipe: rightward",
           play(new(), stroke(121, 400, 700, 1000, 690, 10, 30)),
           with({ swipe(600, -10, 310), tdc(false) }))
    expect("swipe: slower than swipe_max_us is nothing",
           play(new(), stroke(122, 1000, 700, 400, 700, 10, 100)),
           with({ act(1000), tdc(false) }))
    expect("swipe: shorter than swipe_min_frac of the width is nothing",
           play(new(), stroke(123, 1000, 700, 750, 700, 10, 30)), with({ tdc(false) }))
    expect("swipe: under swipe_ratio (diagonal) is nothing",
           play(new(), stroke(124, 1000, 800, 600, 550, 10, 30)), with({ tdc(false) }))
    -- 250 px is under 0.15 x 1872 but over 0.15 x 1404: along physical Y
    -- the panel's height is the logical width (rotations 1 and 3).
    expect("swipe: the length floor follows the dominant physical axis",
           play(new(), stroke(125, 800, 600, 800, 850, 10, 30)),
           with({ swipe(0, 250, 310), tdc(false) }))
end

do
    local K = kernel(0)
    local list = K.frame(0, { { 0, id = 10, x = 1150, y = 300 },
                              { 1, id = 11, x = 1150, y = 600 },
                              { 2, id = 12, x = 1150, y = 900 } })
    for i = 1, 10 do
        local x = 1150 - 40 * i
        list = steps(list, K.frame(30 * i, { { 0, x = x }, { 1, x = x }, { 2, x = x } }))
    end
    list = steps(list, K.frame(330, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 } }))
    expect("multi: three fingers leftward; landing together arms no long press",
           play(new(), list), { act(0), tdc(true), mswipe(-400, 0, 3, 330), tdc(false) })

    -- Five fingers down, three reported: the controller swaps which ones,
    -- drops one and brings it back as a new contact at a new place.
    K = kernel(0)
    list = steps(
        K.frame(0, { { 0, id = 20, x = 1150, y = 300 }, { 1, id = 21, x = 1150, y = 600 },
                     { 2, id = 22, x = 1150, y = 900 } }),
        K.frame(30, { { 0, x = 1110 }, { 1, x = 1110 }, { 2, x = 1110 } }),
        K.frame(60, { { 0, x = 1070 }, { 1, x = 1070 }, { 5, id = 23, x = 1070, y = 1200 },
                      { 2, id = -1 } }),
        K.frame(90, { { 0, x = 1030 }, { 1, x = 1030 }, { 5, x = 1030 } }),
        K.frame(120, { { 0, x = 990 }, { 5, x = 990 }, { 1, id = -1 } }),
        K.frame(150, { { 0, x = 950 }, { 1, id = 24, x = 950, y = 650 }, { 5, x = 950 } }),
        K.frame(180, { { 0, x = 910 }, { 1, x = 910 }, { 5, x = 910 } }),
        K.frame(210, { { 0, id = -1 }, { 1, id = -1 }, { 5, id = -1 } }))
    expect("multi: peak 3 with contacts dropping out and reappearing adds no jump",
           play(new(), list), { act(0), tdc(true), mswipe(-240, 0, 3, 210), tdc(false) })

    K = kernel(0)
    list = K.frame(0, { { 0, id = 30, x = 400, y = 200 }, { 1, id = 31, x = 400, y = 450 },
                        { 2, id = 32, x = 400, y = 700 },
                        { 3, id = 33, x = 400, y = 950 } })
    for i = 1, 6 do
        local x = 400 + 50 * i
        local acts = { { 0, x = x }, { 1, x = x }, { 2, x = x } }
        if i == 3 then
            acts[4] = { 3, id = -1 }
        elseif i == 4 then
            acts[4] = { 3, id = 34, x = x, y = 1000 }
        else
            acts[4] = { 3, x = x }
        end
        list = steps(list, K.frame(30 * i, acts))
    end
    list = steps(list, K.frame(210, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 },
                                      { 3, id = -1 } }))
    expect("multi: peak 4, rightward redo, one contact out and back",
           play(new(), list), { act(0), tdc(true), mswipe(300, 0, 4, 210), tdc(false) })

    K = kernel(0)
    local acts0 = {}
    for s = 0, 4 do acts0[#acts0 + 1] = { s, id = 40 + s, x = 1100, y = 150 + 250 * s } end
    list = K.frame(0, acts0)
    for i = 1, 5 do
        local x = 1100 - 60 * i
        local acts = {}
        for s = 0, 4 do
            if not (s == 4 and i == 2) then acts[#acts + 1] = { s, x = x } end
        end
        if i == 2 then acts[#acts + 1] = { 4, id = -1 } end
        if i == 3 then acts[5] = { 4, id = 45, x = x, y = 1300 } end
        list = steps(list, K.frame(30 * i, acts))
    end
    list = steps(list, K.frame(180, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 },
                                      { 3, id = -1 }, { 4, id = -1 } }))
    expect("multi: peak 5, leftward, one contact out and back",
           play(new(), list), { act(0), tdc(true), mswipe(-300, 0, 5, 180), tdc(false) })

    local function fingers(n, dx, dy, frames, dt_ms)
        local k = kernel(0)
        local a = {}
        for s = 0, n - 1 do a[#a + 1] = { s, id = 50 + s, x = 1100, y = 300 + 300 * s } end
        local l = k.frame(0, a)
        for i = 1, frames do
            local b = {}
            for s = 0, n - 1 do
                b[#b + 1] = { s, x = 1100 + math.floor(dx * i / frames + 0.5),
                              y = 300 + 300 * s + math.floor(dy * i / frames + 0.5) }
            end
            l = steps(l, k.frame(i * dt_ms, b))
        end
        local c = {}
        for s = 0, n - 1 do c[#c + 1] = { s, id = -1 } end
        return steps(l, k.frame(frames * dt_ms + 10, c))
    end
    expect("multi: two fingers leftward, landing together: the undo swipe, no single gesture",
           play(new(), fingers(2, -400, 0, 10, 30)),
           { act(0), tdc(true), mswipe(-400, 0, 2, 310), tdc(false) })
    expect("multi: two fingers rightward: the redo swipe",
           play(new(), fingers(2, 400, 0, 10, 30)),
           { act(0), tdc(true), mswipe(400, 0, 2, 310), tdc(false) })
    expect("multi: a two-finger tap is nothing",
           play(new(), fingers(2, 0, 0, 3, 30)), { act(0), tdc(true), tdc(false) })

    -- Two contacts, one swiping and one still or barely moving (a thumb
    -- resting on the glass).  Each finger must travel half the swipe's
    -- minimum, 0.5 x multi_min_frac x 1872 = 112.32 px along X.
    local function pair(bdx, frames, adx)
        adx = adx or -400
        local k = kernel(0)
        local l = k.frame(0, { { 0, id = 70, x = 1100, y = 600 },
                               { 1, id = 71, x = 1100, y = 1000 } })
        for i = 1, frames do
            l = steps(l, k.frame(30 * i, {
                { 0, x = 1100 + math.floor(adx * i / frames + 0.5) },
                { 1, x = 1100 + math.floor(bdx * i / frames + 0.5) } }))
        end
        return steps(l, k.frame(30 * frames + 10, { { 0, id = -1 }, { 1, id = -1 } }))
    end
    expect("multi: one finger swiping beside a still one is neither an undo nor a turn",
           play(new(), pair(0, 10)), { act(0), tdc(true), tdc(false) })
    expect("multi: the second finger short of half the minimum (112 px) is nothing",
           play(new(), pair(-112, 8)), { act(0), tdc(true), tdc(false) })
    expect("multi: the second finger at 113 px travels: the swipe",
           play(new(), pair(-113, 8)),
           { act(0), tdc(true), mswipe(-256.5, 0, 2, 250), tdc(false) })
    -- The mean, (-700 + 150) / 2 = -275 px, is a swipe on its own.
    expect("multi: a second finger moving the other way does not count",
           play(new(), pair(150, 8, -700)), { act(0), tdc(true), tdc(false) })

    -- The fingers land in different frames: the first alone arms the long
    -- press; the second cancels it, so its timer finds nothing to fire,
    -- and the pair still swipes.
    K = kernel(0)
    list = K.frame(0, { { 0, id = 72, x = 1100, y = 600 } })
    list = steps(list, K.frame(40, { { 1, id = 73, x = 1100, y = 1000 } }))
    for i = 1, 10 do
        local x = 1100 - 40 * i
        list = steps(list, K.frame(40 + 30 * i, { { 0, x = x }, { 1, x = x } }))
    end
    list = steps(list, timer(700), K.frame(800, { { 0, id = -1 } }),
                 K.frame(820, { { 1, id = -1 } }))
    expect("multi: two fingers landing apart: no long press, no turn, the swipe",
           play(new(), list),
           { tmr(700000), act(0), tdc(true), mswipe(-400, 0, 2, 820), tdc(false) })
    expect("multi: longer than multi_max_us is nothing",
           play(new(), fingers(3, -400, 0, 16, 100)),
           { act(0), tdc(true), act(1000), tdc(false) })
    expect("multi: under multi_ratio (diagonal) is nothing",
           play(new(), fingers(3, -300, -250, 10, 30)), { act(0), tdc(true), tdc(false) })
end

do
    local K = kernel(0)
    local got = play(new(), steps(
        K.frame(0, { { 0, id = 60, x = 600, y = 600 } }),
        K.frame(100, { { 1, id = 61, x = 900, y = 600 } }),
        timer(700),
        K.frame(800, { { 0, id = -1 }, { 1, id = -1 } })))
    expect("single: a second contact cancels the long press and the tap", got, {
        tmr(700000), act(0), tdc(true), tdc(false),
    })

    K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 62, x = 1300, y = 300 } }),
        K.frame(30, { { 0, x = 1340 } }),
        K.frame(60, { { 1, id = 63, x = 1400, y = 450 } }),
        K.frame(90, { { 0, x = 1380 }, { 1, x = 1440 } }),
        K.frame(120, { { 0, id = -1 }, { 1, id = -1 } })))
    expect("single: a second contact ends a panel drag at zero velocity", got, {
        act(0), tdc(true),
        dBegin(1300, 300, 30), dMove(1340, 300, 30),
        dEnd(1340, 300, 60, 0, 0),
        tdc(false),
    })
end

do
    local K = kernel(0)
    local got = play(new(), steps(
        K.frame(0, { { 0, id = 70, x = 1300, y = 300 } }),
        K.frame(30, { { 0, x = 1310 } }),           -- inside the slop
        K.frame(60, { { 0, x = 1340 } }),           -- drag begins at the start point
        K.frame(90, { { 0, x = 1380, y = 320 } }),
        K.frame(400, { { 0, id = -1 } })))          -- still for 310 ms
    expect("drag: begins past the slop, from the start point; a stop is no flick",
           got, {
        act(0), tdc(true),
        dBegin(1300, 300, 60), dMove(1340, 300, 60), dMove(1380, 320, 90),
        dEnd(1380, 320, 400, 0, 0),
        tdc(false),
    })

    K = kernel(0)
    local list = K.frame(0, { { 0, id = 71, x = 1300, y = 300 } })
    local want = { act(0), tdc(true), dBegin(1300, 300, 10) }
    for i = 1, 10 do
        list = steps(list, K.frame(10 * i, { { 0, x = 1300 + 30 * i } }))
        want[#want + 1] = dMove(1300 + 30 * i, 300, 10 * i)
    end
    list = steps(list, K.frame(105, { { 0, id = -1 } }))
    want[#want + 1] = dEnd(1600, 300, 105, 3000, 0)
    want[#want + 1] = tdc(false)
    expect("drag: flick velocity is px/s over the last flick_window_us",
           play(new(), list), want)

    K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 72, x = 1300, y = 300 } }),
        K.frame(50, { { 0, x = 1330 } }),
        K.frame(100, { { 0, x = 1335 } }),
        K.frame(200, { { 0, x = 1340 } }),
        K.frame(300, { { 0, x = 1345 } }),
        K.frame(350, { { 0, x = 1395 } }),
        K.frame(400, { { 0, x = 1445 } }),
        K.frame(410, { { 0, id = -1 } })))
    local last_end = got[#got - 1]
    report(last_end.k == "drag_end" and last_end.vx == 1000 and last_end.vy == 0,
           "drag: only the last window counts (slow drag, fast finish)", fmt(last_end))

    K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 73, x = 1300, y = 300 } }),
        K.frame(20, { { 0, x = 1340 } }),
        K.frame(40, { { 0, x = 1380, y = 280 } }),
        K.frame(50, { { 0, id = -1 } })))
    last_end = got[#got - 1]
    report(last_end.k == "drag_end" and last_end.vx == 1600 and last_end.vy == -400,
           "drag: a contact younger than the window is measured over its life",
           fmt(last_end))
end

do
    local got = play(new(), steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        touch(10, "ID", 80, "MX", 500, "MY", 700),
        touch(40, "MX", 900),
        touch(60, "ID", -1)))
    expect("palm: a contact starting while the pen is in range is invisible but down",
           got, {
        prox(true, "pen", 0), tdc(true), tdc(false),
    })

    got = play(new(), steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        pen(100, "PEN", 0),
        touch(599, "ID", 81, "MX", 500, "MY", 700),  -- 499 ms after the pen left
        touch(640, "ID", -1),
        touch(700, "ID", 82, "MX", 510, "MY", 700),  -- 600 ms after
        touch(750, "ID", -1)))
    expect("palm: rejected inside palm_grace_us after the pen left, accepted after", got, {
        prox(true, "pen", 0), prox(false, "pen", 100),
        tdc(true), tdc(false),
        tmr(700000), act(700), tdc(true), tap(510, 700, 750, "canvas"), tdc(false),
    })

    got = play(new(), steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        pen(600, "PEN", 0),
        touch(1100, "ID", 83, "MX", 500, "MY", 700), -- exactly palm_grace_us after
        touch(1150, "ID", -1)))
    expect("palm: accepted from exactly palm_grace_us", got, {
        prox(true, "pen", 0), prox(false, "pen", 600),
        tmr(700000), act(1100), tdc(true), tap(500, 700, 1150, "canvas"), tdc(false),
    })

    -- One batch, drained fd by fd: the pen's prox-out arrives first, the
    -- touch that began 10 ms BEFORE it arrives after.
    got = play(new(), steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        pen(1000, "PEN", 0),
        touch(990, "ID", 84, "MX", 500, "MY", 700),
        touch(1050, "ID", -1)))
    expect("palm: a contact stamped before the pen left is rejected, arriving after",
           got, {
        prox(true, "pen", 0), prox(false, "pen", 1000), tdc(true), tdc(false),
    })
end

do
    local got = play(new(), steps(
        touch(0, "ID", 90, "MX", 500, "MY", 700),   -- the palm lands first
        pen(100, "PEN", 1, "X", 5000, "Y", 5000),
        pen(150, "PEN", 0),
        touch(200, "ID", -1)))                      -- tap timing, but vetoed
    expect("veto: the pen entering during a contact vetoes its gesture", got, {
        tmr(700000), act(0), tdc(true),
        prox(true, "pen", 100), prox(false, "pen", 150),
        tdc(false),
    })

    got = play(new(), steps(
        touch(0, "ID", 91, "MX", 500, "MY", 700),
        pen(100, "PEN", 1, "X", 5000, "Y", 5000),
        pen(200, "PEN", 0),
        timer(700),
        touch(800, "ID", -1)))
    expect("veto: covers the long press, by timer and by late lift", got, {
        tmr(700000), act(0), tdc(true),
        prox(true, "pen", 100), prox(false, "pen", 200),
        tdc(false),
    })

    -- A palm resting past longpress_us before the pen arrives: its long
    -- press has already fired by timer, so the veto says so.
    got = play(new(), steps(
        touch(0, "ID", 96, "MX", 500, "MY", 700),
        timer(700),
        pen(900, "PEN", 1, "X", 5000, "Y", 5000),
        pen(950, "PEN", 0),
        pen(960, "PEN", 1),
        touch(1000, "ID", -1)))
    expect("veto: a long press that fired on a contact still down is taken back, once",
           got, {
        tmr(700000), act(0), tdc(true), lp(500, 700, 700),
        prox(true, "pen", 900), { k = "long_press_vetoed", t = ms(900) },
        prox(false, "pen", 950), prox(true, "pen", 960),
        tdc(false),
    })

    local list = touch(0, "ID", 92, "MX", 1000, "MY", 700)
    for i = 1, 10 do
        list = steps(list, touch(30 * i, "MX", 1000 - 60 * i))
        if i == 3 then list = steps(list, pen(95, "PEN", 1, "X", 5000, "Y", 5000)) end
    end
    list = steps(list, touch(310, "ID", -1))
    expect("veto: a palm sliding like a swipe while the pen hovers", play(new(), list), {
        tmr(700000), act(0), tdc(true), prox(true, "pen", 95), tdc(false),
    })

    got = play(new(), steps(
        touch(0, "ID", 93, "MX", 1300, "MY", 300),
        touch(30, "MX", 1340),
        pen(40, "PEN", 1, "X", 5000, "Y", 5000),
        touch(60, "MX", 1400),
        touch(90, "ID", -1)))
    expect("veto: the pen arriving ends a panel drag at zero velocity", got, {
        act(0), tdc(true),
        dBegin(1300, 300, 30), dMove(1340, 300, 30),
        prox(true, "pen", 40), dEnd(1340, 300, 40, 0, 0),
        tdc(false),
    })

    got = play(new(), steps(
        touch(0, "ID", 94, "MX", 500, "MY", 700),
        resync({ prox = true, tool = "pen", touching = false }, 50),
        touch(100, "ID", -1)))
    expect("veto: proximity from a resync snapshot vetoes too", got, {
        tmr(700000), act(0), tdc(true), prox(true, "pen", 50), tdc(false),
    })

    -- A vetoed contact is a palm: once the pen has gone it may keep
    -- sliding, and that is not the operator's activity.
    got = play(new(), steps(
        touch(0, "ID", 95, "MX", 500, "MY", 700),
        pen(100, "PEN", 1, "X", 5000, "Y", 5000),
        pen(200, "PEN", 0),
        touch(1500, "MX", 600),
        touch(2600, "MX", 700),
        touch(2700, "ID", -1)))
    expect("veto: a vetoed contact's later travel is no activity", got, {
        tmr(700000), act(0), tdc(true),
        prox(true, "pen", 100), prox(false, "pen", 200),
        tdc(false),
    })
end

do
    -- A palm rejected while the pen hovered stays down; a finger after
    -- the grace still taps, and the down state tracks every contact.
    local K = kernel(0)
    local inp = new()
    local list = {
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        K.frame(10, { { 0, id = 100, x = 300, y = 1200 } }),
        pen(20, "PEN", 0),
        K.frame(600, { { 1, id = 101, x = 800, y = 700 } }),
        K.frame(650, { { 1, id = -1 } }),
        K.frame(700, { { 0, id = -1 } }),
    }
    local got, downs = {}, {}
    for _, l in ipairs(list) do
        got = steps(got, play(inp, l))
        downs[#downs + 1] = tostring(inp:any_touch_down())
    end
    expect("touch_down_changed: flips at the first contact down (palms too), last up",
           got, {
        prox(true, "pen", 0), tdc(true), prox(false, "pen", 20),
        tmr(700000), act(600), tap(800, 700, 650, "canvas"),
        tdc(false),
    })
    local d = table.concat(downs, ",")
    report(d == "false,true,true,true,true,false",
           "any_touch_down across the same stream", d)
end

do
    local K = kernel(0)
    local got = play(new(), steps(
        K.frame(0, { { 0, id = 110, x = 1000, y = 700 } }),
        K.frame(30, { { 0, x = 900 } }),
        drop("touch", 60),
        syn("touch", ms(60)),
        K.frame(90, { { 0, x = 700 } }),
        K.frame(120, { { 0, x = 400 } }),
        K.frame(150, { { 0, id = -1 } })))   -- a 600 px swipe but for the drop
    expect("touch SYN_DROPPED: the gesture it cut fires nothing", got, {
        tmr(700000), act(0), tdc(true), tdc(false),
    })

    -- A palm left down (rejected while the pen hovered) holds the block
    -- after a drop: a finger tap fires only once every contact has lifted.
    K = kernel(0)
    got = play(new(), steps(
        pen(0, "PEN", 1, "X", 5000, "Y", 5000),
        K.frame(10, { { 0, id = 111, x = 300, y = 1200 } }),
        pen(20, "PEN", 0),
        drop("touch", 700),
        syn("touch", ms(700)),
        K.frame(800, { { 1, id = 112, x = 800, y = 700 } }),
        K.frame(850, { { 1, id = -1 } }),
        K.frame(900, { { 0, id = -1 } }),
        K.frame(1000, { { 1, id = 113, x = 800, y = 700 } }),
        K.frame(1050, { { 1, id = -1 } })))
    expect("touch SYN_DROPPED: nothing fires until every contact (palms too) lifts",
           got, {
        prox(true, "pen", 0), tdc(true), prox(false, "pen", 20),
        act(800), tdc(false),
        tmr(700000), tdc(true), tap(800, 700, 1050, "canvas"), tdc(false),
    })

    -- The cut report is still tracked: its ABS_MT_SLOT and the contact
    -- after it are real, and later frames address that slot unnamed.
    K = kernel(0)
    local inp = new()
    local parts = {
        K.frame(0, { { 0, id = 114, x = 1000, y = 700 } }),
        steps(drop("touch", 30),
              bare("touch", ms(30), { "SLOT", 2, "ID", 115, "MX", 400, "MY", 400 }),
              syn("touch", ms(30))),
    }
    K.slot, K.x[2], K.y[2] = 2, 400, 400
    parts[3] = K.frame(60, { { 2, x = 420 } })     -- no ABS_MT_SLOT: still slot 2
    parts[4] = K.frame(90, { { 0, id = -1 } })
    parts[5] = K.frame(120, { { 2, id = -1 } })
    local downs = {}
    got = {}
    for _, part in ipairs(parts) do
        got = steps(got, play(inp, part))
        downs[#downs + 1] = tostring(inp:any_touch_down())
    end
    local d = table.concat(downs, ",")
    report(d == "true,true,true,true,false",
           "touch SYN_DROPPED: the cut report's slot and contact are tracked", d)

    K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 113, x = 1300, y = 300 } }),
        K.frame(30, { { 0, x = 1340 } }),
        drop("touch", 60),
        syn("touch", ms(60)),
        K.frame(90, { { 0, x = 1400 } }),
        K.frame(120, { { 0, id = -1 } })))
    expect("touch SYN_DROPPED: ends a panel drag at zero velocity", got, {
        act(0), tdc(true),
        dBegin(1300, 300, 30), dMove(1340, 300, 30),
        dEnd(1340, 300, 60, 0, 0),
        tdc(false),
    })

    got = play(new(), steps(
        drop("touch", 0),
        syn("touch", ms(0)),
        touch(10, "ID", 114, "MX", 500, "MY", 700),
        touch(60, "ID", -1)))
    expect("touch SYN_DROPPED with nothing down blocks nothing after its report", got, {
        tmr(700000), act(10), tdc(true), tap(500, 700, 60, "canvas"), tdc(false),
    })
end

do
    -- The kernel's current slot is 2 when the notebook opens, so the
    -- first contact's events carry no ABS_MT_SLOT.
    local function stream()
        local K = kernel(2)
        local list = steps(
            K.frame(0, { { 2, id = 120, x = 1150, y = 300 } }),
            K.frame(20, { { 0, id = 121, x = 1150, y = 600 } }),
            K.frame(40, { { 1, id = 122, x = 1150, y = 900 } }))
        for i = 1, 8 do
            local x = 1150 - 40 * i
            list = steps(list, K.frame(40 + 30 * i,
                                       { { 2, x = x }, { 0, x = x }, { 1, x = x } }))
        end
        return steps(list, K.frame(310, { { 2, id = -1 }, { 0, id = -1 }, { 1, id = -1 } }))
    end
    local inp = new()
    inp:set_touch_slot(2)
    expect("set_touch_slot: the unnamed first slot is the kernel's; three fingers seen",
           play(inp, stream()), {
               tmr(700000), act(0), tdc(true), mswipe(-320, 0, 3, 310), tdc(false),
           })
    inp = new()
    local got = play(inp, stream())
    -- The first finger's events go to slot 0, where the second finger's
    -- contact then replaces it: two fingers seen, not three.
    expect("set_touch_slot: without it the first contact lands in slot 0; a finger lost",
           got, { tmr(700000), act(0), tdc(true), mswipe(-320, 0, 2, 310), tdc(false) })
    report(not inp:any_touch_down(),
           "set_touch_slot: the stale-slot stream still leaves nothing down")
end

------------------------------------------------------------------------
-- Boundaries and unusual orders
------------------------------------------------------------------------

-- Microsecond-exact frames for the threshold checks.
local function touch_us(t_us, ...) return frame("touch", T0 + t_us, { ... }) end
local function timer_us(t_us) return { { timer = T0 + t_us } } end
local function at(t_us) return t_us / 1000 end -- for the ms-based constructors

do
    local inp = new()
    local got = play(inp, steps(
        pen(0, "TOUCH", 1, "P", 800, "PEN", 1, "X", 4000, "Y", 3000),
        pen(3, "X", 4010),
        pen(6, "TOUCH", 0, "P", 0)))
    expect("pen: BTN_TOUCH before the tool key in one report: prox first, then the stroke",
           got, {
        prox(true, "pen", 0),
        begin("pen", 0, 4000, 3000, 800),
        act(0),
        point(3, 4010, 3000, 800),
        sEnd(6, false),
    })

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 4000, "Y", 3000),
        pen(3, "RUBBER", 1),          -- both keys down: the newer tool wins
        pen(6, "PEN", 0),             -- the pen's own release changes nothing
        pen(9, "PEN", 1, "RUBBER", 0),
        pen(12, "TOUCH", 1, "P", 900)))
    expect("pen: with both tool keys down the most recent BTN_TOOL_*:1 is the tool",
           got, {
        prox(true, "pen", 0),
        prox(false, "pen", 3), prox(true, "rubber", 3),
        prox(false, "rubber", 9), prox(true, "pen", 9),
        begin("pen", 12, 4000, 3000, 900),
        act(12),
    })

    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 4000, "Y", 3000),
        pen(3, "TOUCH", 1, "P", 900),
        drop("pen", 6),
        drop("pen", 6),               -- a second overflow before the report ends
        syn("pen", ms(6)),
        pen(9, "X", 4100)))
    expect("pen: two SYN_DROPPED in one cut report end the stroke once, resync once",
           got, {
        prox(true, "pen", 0),
        begin("pen", 3, 4000, 3000, 900),
        act(3),
        sEnd(6, true),
        PEN_RESYNC,
    })

    -- The tool changed inside the lost window: the snapshot says rubber.
    got = play(inp, steps(
        resync({ prox = true, tool = "rubber", touching = true }, 10),
        pen(12, "X", 4200),
        pen(15, "TOUCH", 0, "P", 0),
        pen(18, "TOUCH", 1, "P", 500)))
    expect("pen: a snapshot with another tool switches it; ink waits for BTN_TOUCH:1",
           got, {
        prox(false, "pen", 10), prox(true, "rubber", 10),
        begin("rubber", 18, 4200, 3000, 500),
    })

    -- The snapshot is "now"; the rest of the batch is older but still after
    -- the drop, so its transitions are real and replay on top of it.
    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 4000, "Y", 3000),
        drop("pen", 5),
        syn("pen", ms(5)),
        resync({ prox = true, tool = "pen", touching = true }, 8),
        pen(6, "TOUCH", 1, "P", 700, "X", 4050),
        pen(7, "X", 4060)))
    expect("pen: a real BTN_TOUCH:1 queued behind the snapshot still starts a stroke",
           got, {
        prox(true, "pen", 0),
        PEN_RESYNC,
        begin("pen", 6, 4050, 3000, 700),
        act(6),
        point(7, 4060, 3000, 700),
    })

    -- A reader buffer smaller than a packet splits it across reads, and
    -- an overflow then drops the unread rest: a BTN_TOUCH:1 can reach
    -- SYN_DROPPED with no SYN_REPORT after it.  It is not a contact.
    inp = new()
    got = play(inp, steps(
        pen(0, "PEN", 1, "X", 4000, "Y", 3000),
        bare("pen", ms(3), { "TOUCH", 1, "P", 900 }),
        drop("pen", 3),
        syn("pen", ms(3)),
        pen(6, "X", 4010)))
    expect("pen: a BTN_TOUCH:1 cut off by SYN_DROPPED starts no stroke", got, {
        prox(true, "pen", 0),
        PEN_RESYNC,
    })

    local r = inp:feed({ t = ms(9), type = 3, code = 0, value = 1 })
    local r2 = inp:feed({ src = "gsensor", t = ms(9), type = 4, code = 71, value = 1 })
    report(rawequal(r, Input.NONE) and rawequal(r2, Input.NONE),
           "feed: an event with no or a foreign src is swallowed")

    -- Activity at exactly the interval fires; one microsecond less does not.
    inp = new()
    local list = steps(pen(0, "PEN", 1, "X", 4000, "Y", 3000),
                       pen(1, "TOUCH", 1, "P", 900))
    list = steps(list, frame("pen", ms(1) + 999999, { "X", 4001 }),
                 frame("pen", ms(1) + 1000000, { "X", 4002 }))
    local ts = {}
    for _, it in ipairs(play(inp, list)) do
        if it.k == "activity" then ts[#ts + 1] = tostring(it.t - T0) end
    end
    report(table.concat(ts, ",") == "1000,1001000",
           "activity: fires at exactly activity_min_interval_us, not a microsecond before",
           "us " .. table.concat(ts, ","))
end

do
    local function one(x1, y1, lift_us)
        return steps(touch_us(0, "ID", 200, "MX", 500, "MY", 700),
                     touch_us(50000, "MX", x1, "MY", y1),
                     touch_us(lift_us, "ID", -1))
    end
    expect("tap: exactly tap_max_us and tap_slop_px is a tap (start point reported)",
           play(new(), one(524, 700, 400000)),
           { tmr(700000), act(0), tdc(true), tap(500, 700, at(400000), "canvas"),
             tdc(false) })
    expect("tap: one microsecond past tap_max_us is not",
           play(new(), one(524, 700, 400001)),
           { tmr(700000), act(0), tdc(true), tdc(false) })
    expect("tap: one pixel past tap_slop_px is not",
           play(new(), one(525, 700, 300000)),
           { tmr(700000), act(0), tdc(true), tdc(false) })

    expect("long press: fires at exactly longpress_us; a microsecond early re-arms for 1 us",
           play(new(), steps(touch_us(0, "ID", 201, "MX", 500, "MY", 700),
                             timer_us(699999), timer_us(700000),
                             touch_us(900000, "ID", -1))),
           { tmr(700000), act(0), tdc(true), tmr(1), lp(500, 700, at(700000)),
             tdc(false) })
    expect("long press: exactly longpress_slop_px of wander still counts",
           play(new(), steps(touch_us(0, "ID", 202, "MX", 500, "MY", 700),
                             touch_us(100000, "MX", 524),
                             touch_us(200000, "MX", 500),
                             timer_us(700000))),
           { tmr(700000), act(0), tdc(true), lp(500, 700, at(700000)) })
    expect("long press: one pixel more cancels it, even after the finger comes back",
           play(new(), steps(touch_us(0, "ID", 203, "MX", 500, "MY", 700),
                             touch_us(100000, "MX", 525),
                             touch_us(200000, "MX", 500),
                             timer_us(700000),
                             touch_us(800000, "ID", -1))),
           { tmr(700000), act(0), tdc(true), tdc(false) })
    expect("long press: none on the panel, whatever on_timer is called with",
           play(new(), steps(touch_us(0, "ID", 204, "MX", 1300, "MY", 300),
                             timer_us(700000),
                             touch_us(900000, "ID", -1))),
           { act(0), tdc(true), tdc(false) })

    -- A timer armed for an earlier contact reaches a later one.
    expect("long press: a stale timer re-arms for the new contact's remainder",
           play(new(), steps(touch_us(0, "ID", 205, "MX", 500, "MY", 700),
                             touch_us(100000, "ID", -1),
                             touch_us(500000, "ID", 206, "MX", 600, "MY", 700),
                             timer_us(700000))),
           { tmr(700000), act(0), tdc(true), tap(500, 700, at(100000), "canvas"),
             tdc(false), tmr(700000), tdc(true), tmr(500000) })
    local inp = new()
    local r1 = inp:on_timer(T0)
    play(inp, steps(touch_us(0, "ID", 207, "MX", 500, "MY", 700),
                    touch_us(900000, "ID", -1)))
    local r2 = inp:on_timer(T0 + 1000000)
    report(rawequal(r1, Input.NONE) and rawequal(r2, Input.NONE),
           "long press: on_timer with no contact down is NONE")
end

do
    -- One contact from (x0,y0) by (dx,dy) in 10 frames, lifting at lift_us.
    local function swipe_us(x0, y0, dx, dy, lift_us)
        local list = touch_us(0, "ID", 210, "MX", x0, "MY", y0)
        for i = 1, 10 do
            list = steps(list, touch_us(20000 * i,
                                        "MX", x0 + math.floor(dx * i / 10 + 0.5),
                                        "MY", y0 + math.floor(dy * i / 10 + 0.5)))
        end
        return steps(list, touch_us(lift_us, "ID", -1))
    end
    local function fired(list)
        for _, it in ipairs(play(new(), list)) do
            if it.k == "swipe" then return fmt(it) end
        end
        return "none"
    end
    -- 0.15 x 1872 = 280.8 and 0.15 x 1404 = 210.6.
    local s = table.concat({
        fired(swipe_us(1000, 700, -281, 0, 300000)),
        fired(swipe_us(1000, 700, -280, 0, 300000)),
        fired(swipe_us(900, 500, 0, 211, 300000)),
        fired(swipe_us(900, 500, 0, 210, 300000)),
        fired(swipe_us(1000, 700, -300, 150, 300000)),
        fired(swipe_us(1000, 700, -300, 151, 300000)),
        fired(swipe_us(1000, 700, -300, 0, 900000)),
        fired(swipe_us(1000, 700, -300, 0, 900001)),
    }, " / ")
    report(s == "swipe t=300000 dx=-281 dy=0 / none / swipe t=300000 dx=0 dy=211 / none"
               .. " / swipe t=300000 dx=-300 dy=150 / none"
               .. " / swipe t=900000 dx=-300 dy=0 / none",
           "swipe: length floor per physical axis, swipe_ratio and swipe_max_us are inclusive",
           s)

    -- 0.15 of either extent is fractional, so the floor's own boundary
    -- needs a fraction that lands on a pixel: 0.25 x 1872 = 468.
    local quarter = Input.new(config({ swipe_min_frac = 0.25 }), hit)
    local q = play(quarter, swipe_us(1000, 700, -468, 0, 300000))[4]
    report(q and q.k == "swipe" and q.dx == -468,
           "swipe: travel of exactly swipe_min_frac of the extent is a swipe",
           q and fmt(q) or "none")

    -- The controller turns the physical delta into a logical one.  In the
    -- seeded portrait (mode 1, bb rotation 3) a physical downward swipe is
    -- logical LEFT, the next page; in mode 3 (bb rotation 1) it is right.
    local G = require("nb_geom")
    local d = fmt(play(new(), swipe_us(900, 300, 0, 400, 300000))[4])
    local l3 = { G.delta_to_logical(G.bb_rotation(1), 0, 400) }
    local l1 = { G.delta_to_logical(G.bb_rotation(3), 0, 400) }
    report(d == "swipe t=300000 dx=0 dy=400" and l3[1] == -400 and l3[2] == 0
           and l1[1] == 400 and l1[2] == 0,
           "swipe: physical +y is logical left in mode 1 and right in mode 3",
           string.format("%s; mode 1 -> %d,%d; mode 3 -> %d,%d", d, l3[1], l3[2],
                         l1[1], l1[2]))
end

do
    local function three(dur_us)
        local K = kernel(0)
        local list = K.frame(0, { { 0, id = 220, x = 1100, y = 300 },
                                  { 1, id = 221, x = 1100, y = 600 },
                                  { 2, id = 222, x = 1100, y = 900 } })
        for i = 1, 4 do
            local x = 1100 - 60 * i
            list = steps(list, K.frame(at(100000 * i),
                                       { { 0, x = x }, { 1, x = x }, { 2, x = x } }))
        end
        local last = K.frame(0, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 } })
        for _, ev in ipairs(last) do ev.t = T0 + dur_us end
        return steps(list, last)
    end
    expect("multi: exactly multi_max_us is a multi_swipe",
           play(new(), three(1500000)),
           { act(0), tdc(true), mswipe(-240, 0, 3, at(1500000)), tdc(false) })
    expect("multi: one microsecond more is not",
           play(new(), three(1500001)),
           { act(0), tdc(true), tdc(false) })

    -- Fingers land over three frames: the first arms the long press, the
    -- timer finds a multi-finger session and stays quiet.
    local K = kernel(0)
    local list = steps(
        K.frame(0, { { 0, id = 223, x = 1100, y = 300 } }),
        K.frame(15, { { 1, id = 224, x = 1100, y = 600 } }),
        K.frame(30, { { 2, id = 225, x = 1100, y = 900 } }))
    for i = 1, 6 do
        local x = 1100 - 50 * i
        list = steps(list, K.frame(30 + 30 * i, { { 0, x = x }, { 1, x = x }, { 2, x = x } }))
    end
    list = steps(list, timer(700),
                 K.frame(900, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 } }))
    expect("multi: staggered landings arm, then the timer sees several contacts",
           play(new(), list),
           { tmr(700000), act(0), tdc(true), mswipe(-300, 0, 3, 900), tdc(false) })

    K = kernel(0)
    list = K.frame(0, { { 0, id = 226, x = 1100, y = 300 }, { 1, id = 227, x = 1100, y = 600 },
                        { 2, id = 228, x = 1100, y = 900 } })
    for i = 1, 6 do
        local x = 1100 - 50 * i
        list = steps(list, K.frame(30 * i, { { 0, x = x }, { 1, x = x }, { 2, x = x } }))
        if i == 2 then list = steps(list, pen(65, "PEN", 1, "X", 5000, "Y", 5000)) end
    end
    list = steps(list, K.frame(210, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 } }))
    expect("multi: the pen entering mid-gesture vetoes a multi_swipe",
           play(new(), list), { act(0), tdc(true), prox(true, "pen", 65), tdc(false) })

    K = kernel(0)
    list = K.frame(0, { { 0, id = 229, x = 1100, y = 300 }, { 1, id = 230, x = 1100, y = 600 },
                        { 2, id = 231, x = 1100, y = 900 } })
    for i = 1, 6 do
        local x = 1100 - 50 * i
        list = steps(list, K.frame(30 * i, { { 0, x = x }, { 1, x = x }, { 2, x = x } }))
        if i == 2 then list = steps(list, drop("touch", 65), syn("touch", ms(65))) end
    end
    list = steps(list, K.frame(210, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 } }))
    expect("multi: a touch SYN_DROPPED mid-gesture cancels the multi_swipe",
           play(new(), list), { act(0), tdc(true), tdc(false) })

    -- A palm rejected while the pen hovered stays down; three fingers
    -- after the grace still swipe, and the palm is not one of them.
    K = kernel(0)
    list = steps(pen(0, "PEN", 1, "X", 5000, "Y", 5000),
                 K.frame(10, { { 5, id = 232, x = 300, y = 1300 } }),
                 pen(20, "PEN", 0),
                 K.frame(600, { { 0, id = 233, x = 1100, y = 300 },
                                { 1, id = 234, x = 1100, y = 600 },
                                { 2, id = 235, x = 1100, y = 900 } }))
    for i = 1, 6 do
        local x = 1100 - 50 * i
        list = steps(list, K.frame(600 + 30 * i, { { 0, x = x }, { 1, x = x }, { 2, x = x } }))
    end
    list = steps(list, K.frame(810, { { 0, id = -1 }, { 1, id = -1 }, { 2, id = -1 } }),
                 K.frame(900, { { 5, id = -1 } }))
    expect("multi: a resting palm neither counts as a finger nor blocks the swipe",
           play(new(), list), {
        prox(true, "pen", 0), tdc(true), prox(false, "pen", 20),
        act(600), mswipe(-300, 0, 3, 810), tdc(false),
    })

    -- Two fingers are now enough for an undo, so a rejected palm must
    -- still count for nothing: beside one finger it leaves a page turn,
    -- beside two an undo of two fingers.
    local function palm_then(fingers)
        K = kernel(0)
        local acts = {}
        for s = 0, fingers - 1 do
            acts[#acts + 1] = { s, id = 236 + s, x = 1100, y = 300 + 300 * s }
        end
        list = steps(pen(0, "PEN", 1, "X", 5000, "Y", 5000),
                     K.frame(10, { { 5, id = 240, x = 300, y = 1300 } }),
                     pen(20, "PEN", 0), K.frame(600, acts))
        for i = 1, 6 do
            local x, mv = 1100 - 50 * i, {}
            for s = 0, fingers - 1 do mv[#mv + 1] = { s, x = x } end
            -- The palm slides with them: rejected, its travel is nothing.
            mv[#mv + 1] = { 5, x = 300 - 50 * i }
            list = steps(list, K.frame(600 + 30 * i, mv))
        end
        local up = {}
        for s = 0, fingers - 1 do up[#up + 1] = { s, id = -1 } end
        return steps(list, K.frame(810, up), K.frame(900, { { 5, id = -1 } }))
    end
    expect("multi: a sliding rejected palm beside one finger: a page turn, not an undo",
           play(new(), palm_then(1)), {
        prox(true, "pen", 0), tdc(true), prox(false, "pen", 20),
        tmr(700000), act(600), swipe(-300, 0, 810), tdc(false),
    })
    expect("multi: a sliding rejected palm beside two fingers: an undo of two",
           play(new(), palm_then(2)), {
        prox(true, "pen", 0), tdc(true), prox(false, "pen", 20),
        act(600), mswipe(-300, 0, 2, 810), tdc(false),
    })
end

do
    local K = kernel(0)
    local got = play(new(), steps(
        K.frame(0, { { 0, id = 240, x = 1300, y = 300 } }),
        K.frame(30, { { 0, x = 1324 } }),       -- exactly the slop: still a tap
        K.frame(60, { { 0, x = 1325 } }),       -- one more pixel: a drag
        K.frame(90, { { 0, id = -1 } })))
    expect("drag: exactly tap_slop_px is not a drag; one pixel more begins it", got, {
        act(0), tdc(true),
        dBegin(1300, 300, 60), dMove(1325, 300, 60),
        dEnd(1325, 300, 90, 25 * 1e6 / 90000, 0),
        tdc(false),
    })

    -- The finger goes out and comes back: the window sees the return only.
    K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 241, x = 1300, y = 300 } }),
        K.frame(30, { { 0, x = 1340 } }),
        K.frame(60, { { 0, x = 1300 } }),
        K.frame(150, { { 0, id = -1 } })))
    expect("drag: back at the start, the flick is the last window's travel", got, {
        act(0), tdc(true),
        dBegin(1300, 300, 30), dMove(1340, 300, 30), dMove(1300, 300, 60),
        dEnd(1300, 300, 150, -400, 0),
        tdc(false),
    })

    -- Realtime stepped back before the lift: no window, no flick.
    K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 242, x = 1300, y = 300 } }),
        K.frame(30, { { 0, x = 1400 } }),
        K.frame(-500, { { 0, id = -1 } })))
    expect("drag: a lift stamped before the last move is zero velocity", got, {
        act(0), tdc(true),
        dBegin(1300, 300, 30), dMove(1400, 300, 30),
        dEnd(1400, 300, -500, 0, 0),
        tdc(false),
    })

    -- hit() is asked once per session, with the start point in physical px.
    local asked = {}
    local inp = Input.new(config(), function(x, y)
        asked[#asked + 1] = string.format("%s,%s", num(x), num(y))
        return hit(x, y)
    end)
    play(inp, steps(
        K.frame(1000, { { 0, id = 243, x = 1599, y = 499 } }),
        K.frame(1010, { { 1, id = 244, x = 1600, y = 499 } }),
        K.frame(1020, { { 0, id = -1 }, { 1, id = -1 } }),
        K.frame(1100, { { 1, id = 245, x = 1600, y = 499 } }),
        K.frame(1150, { { 1, id = -1 } })))
    report(table.concat(asked, " ") == "1599,499 1600,499",
           "hit: asked once per session with the start point", table.concat(asked, " "))
end

do
    -- Codes outside the recognizer's set, and contacts it never saw start
    -- (down when the notebook opened), change nothing.
    local inp = new()
    local list = steps(
        touch(0, "MAJ", 30, "MP", 80),
        { { src = "touch", t = ms(0), type = 1, code = 330, value = 1 } },
        { { src = "touch", t = ms(0), type = 4, code = 0, value = 900 } },
        syn("touch", ms(0)),
        touch(10, "MX", 700, "MY", 700),       -- slot 0 moves: nobody there
        touch(20, "ID", -1))                   -- and lifts
    local got = play(inp, list)
    expect("touch: foreign codes and a contact from before open are ignored", got, {})
    -- The orphan's moves were the kernel's slot-0 values, so a new contact
    -- there that sends no position starts from them.
    got = play(inp, steps(touch(100, "ID", 250), touch(150, "ID", -1)))
    expect("touch: a slot's latched position carries into its next contact", got, {
        tmr(700000), act(100), tdc(true), tap(700, 700, 150, "canvas"), tdc(false),
    })
    got = play(new(), steps(touch(100, "ID", 253), touch(150, "ID", -1)))
    expect("touch: a contact with no position ever seen counts but makes no gesture",
           got, { act(100), tdc(true), tdc(false) })

    -- A lift and a landing in one frame: the kernel never reported the two
    -- fingers together, but the frame is committed landing-first, so the
    -- recognizer counts them as one two-contact session and neither fires.
    -- Pinned as the current choice: a single finger the controller re-IDs
    -- mid-swipe then turns no page, rather than two.
    local K = kernel(0)
    got = play(new(), steps(
        K.frame(0, { { 0, id = 251, x = 500, y = 700 } }),
        K.frame(100, { { 1, id = 252, x = 900, y = 700 }, { 0, id = -1 } }),
        K.frame(200, { { 1, id = -1 } })))
    expect("touch: a lift and a landing in one frame make one session, no tap", got, {
        tmr(700000), act(0), tdc(true), tdc(false),
    })
end

report(#Input.NONE == 0 and next(Input.NONE) == nil,
       "Input.NONE is still empty after every case above")

------------------------------------------------------------------------
-- Real captures
------------------------------------------------------------------------

ffi.cdef [[
typedef struct {
    int64_t sec; int64_t usec; uint16_t type; uint16_t code; int32_t value;
} nbtest_input_event;
]]

local function replay(path)
    local f = io.open(path, "rb")
    local data = f:read("*a")
    f:close()
    local n = math.floor(#data / 24)
    local recs = ffi.cast("const nbtest_input_event *", data)
    local inp = Input.new(config(), function() return "canvas" end)
    local interval = base_cfg.activity_min_interval_us
    local r = { touch_down = 0, strokes = 0, pen_strokes = 0, rubber_strokes = 0,
                ends = 0, gaps = 0, points = 0, rubber_in = 0, rubber_in_inked = 0,
                resyncs = 0, bad = 0, out_of_panel = 0, activity = 0,
                activity_close = 0, activity_orphan = 0, open = false }
    local down, in_rubber, rubber_inked = false, false, false
    local last_act, prev
    for i = 0, n - 1 do
        local e = recs[i]
        local ty, code, v = e.type, e.code, e.value
        if ty == 1 and code == 330 and v == 1 then r.touch_down = r.touch_down + 1 end
        local ev = { src = "pen", type = ty, code = code, value = v,
                     t = tonumber(e.sec) * 1000000 + tonumber(e.usec) }
        if ty == 3 and code <= 1 then ev.raw = v end
        local out = inp:feed(ev)
        for j = 1, #out do
            local it = out[j]
            local k = it.k
            if k == "stroke_begin" or k == "stroke_point" then
                if (k == "stroke_begin") == down then r.bad = r.bad + 1 end
                if it.x < 0 or it.x > W - 1 or it.y < 0 or it.y > H - 1 then
                    r.out_of_panel = r.out_of_panel + 1
                end
                if k == "stroke_begin" then
                    down = true
                    r.strokes = r.strokes + 1
                    if it.tool == "rubber" then
                        r.rubber_strokes = r.rubber_strokes + 1
                        if in_rubber then rubber_inked = true end
                    else
                        r.pen_strokes = r.pen_strokes + 1
                    end
                else
                    r.points = r.points + 1
                end
            elseif k == "stroke_end" then
                if not down then r.bad = r.bad + 1 end
                down = false
                r.ends = r.ends + 1
                if it.gap then r.gaps = r.gaps + 1 end
            elseif k == "prox" then
                if it.tool == "rubber" and it.on then
                    r.rubber_in = r.rubber_in + 1
                    in_rubber, rubber_inked = true, false
                elseif it.tool == "rubber" then
                    if rubber_inked then r.rubber_in_inked = r.rubber_in_inked + 1 end
                    in_rubber = false
                end
            elseif k == "activity" then
                r.activity = r.activity + 1
                if last_act and it.t - last_act < interval then
                    r.activity_close = r.activity_close + 1
                end
                last_act = it.t
                if not (prev and prev.t == it.t
                        and (prev.k == "stroke_begin" or prev.k == "stroke_point")) then
                    r.activity_orphan = r.activity_orphan + 1
                end
            elseif k == "pen_resync" then
                r.resyncs = r.resyncs + 1
            else
                r.bad = r.bad + 1
            end
            prev = it
        end
    end
    r.open = down
    return r
end

local captures = {
    { name = "pen-1.bin", touch_down = 156, rubber_in = 2, rubber_strokes = 2, gaps = 4 },
    { name = "pen-3.bin", touch_down = 86, rubber_in = 5, rubber_strokes = 7, gaps = 0 },
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
        local r = replay(capture_dir .. "/" .. c.name)
        report(r.touch_down == c.touch_down and r.strokes == r.touch_down
               and r.ends == r.strokes and not r.open and r.bad == 0,
               c.name .. ": one stroke per BTN_TOUCH:1, every one ended",
               string.format(
                   "%d BTN_TOUCH:1, %d strokes (%d pen, %d rubber), %d ends, %d points",
                   r.touch_down, r.strokes, r.pen_strokes, r.rubber_strokes,
                   r.ends, r.points))
        report(r.rubber_in == c.rubber_in and r.rubber_in_inked == c.rubber_in
               and r.rubber_strokes == c.rubber_strokes,
               c.name .. ": every BTN_TOOL_RUBBER interval yields rubber strokes",
               string.format("%d intervals, %d with ink, %d rubber strokes",
                             r.rubber_in, r.rubber_in_inked, r.rubber_strokes))
        report(r.gaps == c.gaps and r.resyncs == 0 and r.out_of_panel == 0,
               c.name .. ": gap ends only at proximity dropouts, every sample on the panel",
               string.format("%d gap ends", r.gaps))
        report(r.activity > 0 and r.activity_close == 0 and r.activity_orphan == 0,
               c.name .. ": activity only from ink, at most once per interval",
               string.format("%d activity", r.activity))
    end
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
