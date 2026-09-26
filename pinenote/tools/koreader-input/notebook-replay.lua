--[[--
Replay a raw w9013 Stylus capture through the notebook and write what it
drew as PNGs, for looking at real handwriting on the host.

The capture is the byte stream `cat /dev/input/eventN > file` gives on
the device: 24-byte aarch64 struct input_event records (two int64
timeval fields, u16 type, u16 code, s32 value).  It holds digitizer
units, so each ABS_X/ABS_Y goes to nb_controller the way device.lua's
pen hook passes it: the unit as ev.raw, the rounded px as the value.
Every event is fed at its own timestamp; the controller's clock reads
1 ms after it.

The controller's commands are run the way main.lua runs them: ink into
a BB8 page (nb_surface.ink), region render_page into the same page (the
stroke eraser's rebuild, which waits for the pen to leave), resync_pen
answered from the key state seen so far, schedule answered with
on_timer once the capture's clock passes it (one timer, the newest
request replacing the last, as in main.lua), appends kept as the page
file.  Then J.replay of those
lines is rendered into a second page, and the two are compared: they
must be the same pixels, because a reread page is the page the pen drew.

The glue's open-time key snapshot is inferred from the capture: a key
whose first event is a release was down when the capture started (a
capture begun with the pen already in range).

Output: out.png (the live page) and out-replay.png (the rendered
replay), both physical landscape; counts on stdout; exit 0 when the two
pages match, 1 when they differ, 2 on a usage or file error.

This is an instrument, not a gate: the captures are the operator's
handwriting and stay out of the repo (pinenote/tools/pen/build/ is
gitignored).  test-notebook-render.lua is the gate.

Usage: luajit notebook-replay.lua <koreader_dir> <plugin_dir> <capture.bin> \
           <out.png> [brush] [size] [mode]
  brush: fine ballpoint brushpen marker pencil highlighter (default ballpoint)
  size:  S M L (default M)
  mode:  write erase stroke_erase (default write); the rubber end erases
         by area either way
--]]

local function usage(msg)
    io.stderr:write("notebook-replay: " .. msg .. "\n"
        .. "usage: luajit notebook-replay.lua <koreader_dir> <plugin_dir> "
        .. "<capture.bin> <out.png> [brush] [size] [mode]\n")
    os.exit(2)
end

local koreader_dir, plugin_dir, capture, out_png = arg[1], arg[2], arg[3], arg[4]
if not (koreader_dir and plugin_dir and capture and out_png) then
    usage("four arguments are required")
end
local brush, size, mode = arg[5] or "ballpoint", arg[6] or "M", arg[7] or "write"

package.path = table.concat({
    plugin_dir .. "/?.lua",
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
-- ffi/util needs libs/libkoreader-lfs.so
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

-- ffi/loadlib logs through the print it captures when it loads.
local real_print = print
print = function() end
require("ffi/loadlib")
require("ffi/blitbuffer")
print = real_print

local ffi = require("ffi")
local Brush = require("nb_brush")
local Ctl = require("nb_controller")
local J = require("nb_journal")
local Surface = require("nb_surface")
local cfg = require("nb_config")

local format, floor = string.format, math.floor

-- The controller falls back to defaults on unknown prefs; a typo on the
-- command line should say so instead.
local brushes = {}
for _, id in ipairs(Brush.IDS) do brushes[id] = true end
if not brushes[brush] then usage("unknown brush " .. brush) end
if size ~= "S" and size ~= "M" and size ~= "L" then usage("unknown size " .. size) end
if mode ~= "write" and mode ~= "erase" and mode ~= "stroke_erase" then
    usage("unknown mode " .. mode)
end

local replay_png = out_png:gsub("%.png$", "") .. "-replay.png"

------------------------------------------------------------------------
-- The capture
------------------------------------------------------------------------

ffi.cdef [[
typedef struct {
    int64_t sec; int64_t usec; uint16_t type; uint16_t code; int32_t value;
} nbreplay_input_event;
]]

local f, err = io.open(capture, "rb")
if not f then usage(tostring(err)) end
local data = f:read("*a")
f:close()
if #data % 24 ~= 0 then
    io.stderr:write(format("notebook-replay: %d trailing bytes ignored\n", #data % 24))
end

local W, H = cfg.W, cfg.H
local XMAX, YMAX = cfg.abs_x_max, cfg.abs_y_max
local BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH = 320, 321, 330

local recs = ffi.cast("const nbreplay_input_event *", data)
local evs, first_key = {}, {}
for i = 0, floor(#data / 24) - 1 do
    local e = recs[i]
    local ty, code, v = e.type, e.code, e.value
    local ev = { src = "pen", type = ty, code = code, value = v,
                 t = tonumber(e.sec) * 1000000 + tonumber(e.usec) }
    if ty == 3 and code <= 1 then
        ev.raw = v
        local n, max = W, XMAX
        if code == 1 then n, max = H, YMAX end
        ev.value = floor(v * n / max + 0.5)
    elseif ty == 1 and first_key[code] == nil then
        first_key[code] = v
    end
    evs[#evs + 1] = ev
end

-- Key state as a keystate() snapshot would report it.
local down = {
    [BTN_TOOL_PEN] = first_key[BTN_TOOL_PEN] == 0,
    [BTN_TOOL_RUBBER] = first_key[BTN_TOOL_RUBBER] == 0,
    [BTN_TOUCH] = first_key[BTN_TOUCH] == 0,
}
local recent_tool = down[BTN_TOOL_RUBBER] and "rubber" or "pen"
local function snapshot()
    local prox = down[BTN_TOOL_PEN] or down[BTN_TOOL_RUBBER]
    local tool
    if down[BTN_TOOL_PEN] and down[BTN_TOOL_RUBBER] then
        tool = recent_tool
    elseif prox then
        tool = down[BTN_TOOL_RUBBER] and "rubber" or "pen"
    end
    return { prox = prox, tool = tool, touching = down[BTN_TOUCH] }
end

------------------------------------------------------------------------
-- The session
------------------------------------------------------------------------

local NOW = evs[1] and evs[1].t or 0
local function now() return NOW end

local c = Ctl.new{ cfg = cfg, now_rt_us = now, rotation_mode = 0,
                   prefs = { brush = brush, size = size, mode = mode,
                             rubber = "area" } }
local page = Surface.new_page(W, H)
local lines = {}
local timer_at
local st = { ink = 0, spans = 0, publish = 0, renders = 0, resyncs = 0,
             logs = 0, reports = 0, drops = 0, touches = 0 }

local function run(cmds)
    for _, cmd in ipairs(cmds) do
        local op = cmd.op
        if op == "ink" then
            Surface.ink(page, cmd)
            st.ink = st.ink + 1
            st.spans = st.spans + #cmd.spans / 3
        elseif op == "publish_ink" then
            st.publish = st.publish + 1
        elseif op == "append" then
            lines[#lines + 1] = cmd.line
        elseif op == "render_page" and cmd.region then
            -- open's full render of the blank page is left out: the live
            -- page is built from ink alone, apart from the stroke
            -- eraser's pen-up rebuild the glue also runs
            Surface.render_page(page, cmd.page, cmd.strokes, cfg, cmd.region)
            st.renders = st.renders + 1
        elseif op == "resync_pen" then
            st.resyncs = st.resyncs + 1
            run(c:resync(snapshot(), NOW))
        elseif op == "schedule" then
            timer_at = NOW + cmd.delay_us
        elseif op == "log" then
            st.logs = st.logs + 1
        end
    end
end

run(c:open({ id = "20260926T000000Z-000000", title = "replay" }, 0, J.replay({}, cfg)))
run(c:resync(snapshot(), NOW))
run(c:set_ink_live(true))
-- The timer, when the capture's clock has passed it.
local function fire(upto)
    while timer_at and timer_at <= upto do
        NOW, timer_at = timer_at, nil
        run(c:on_timer(NOW))
    end
end

for _, ev in ipairs(evs) do
    fire(ev.t + 1000)
    NOW = ev.t + 1000
    if ev.type == 1 then
        if ev.code == BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER or ev.code == BTN_TOUCH then
            down[ev.code] = ev.value ~= 0
            if ev.value ~= 0 and ev.code ~= BTN_TOUCH then
                recent_tool = ev.code == BTN_TOOL_RUBBER and "rubber" or "pen"
            end
        end
        if ev.code == BTN_TOUCH and ev.value == 1 then st.touches = st.touches + 1 end
    elseif ev.type == 0 and ev.code == 0 then
        st.reports = st.reports + 1
    elseif ev.type == 0 and ev.code == 3 then
        st.drops = st.drops + 1
    end
    run(c:feed(ev))
end
fire(math.huge)
run(c:close())

------------------------------------------------------------------------
-- The replay, the comparison, the PNGs
------------------------------------------------------------------------

local rp = J.replay(lines, cfg)
local replayed = Surface.new_page(W, H)
Surface.render_page(replayed, 0, rp.strokes, cfg)

local s_recs, x_recs, erasers, erased = 0, 0, 0, 0
for _, line in ipairs(lines) do
    local rec = J.decode(line)
    if rec and rec.k == "s" then
        s_recs = s_recs + 1
        if rec.tool == "eraser" then erasers = erasers + 1 end
    elseif rec and rec.k == "x" then
        x_recs = x_recs + 1
        erased = erased + #rec.ids
    end
end

local function black(bb)
    local n = 0
    for y = 0, bb.h - 1 do
        local p = ffi.cast("uint8_t *", bb.data) + bb.stride * y
        for x = 0, bb.w - 1 do if p[x] == 0 then n = n + 1 end end
    end
    return n
end
local differ = 0
for y = 0, H - 1 do
    local p = ffi.cast("uint8_t *", page.data) + page.stride * y
    local q = ffi.cast("uint8_t *", replayed.data) + replayed.stride * y
    for x = 0, W - 1 do if p[x] ~= q[x] then differ = differ + 1 end end
end

print(format("capture: %s", capture:match("[^/]*$")))
print(format("events %d, pen reports %d, SYN_DROPPED %d, resyncs %d",
             #evs, st.reports, st.drops, st.resyncs))
print(format("brush %s %s, mode %s, rubber area", brush, size, mode))
print(format("pen-downs %d: stroke records %d (%d eraser), stroke erases %d (%d strokes), "
             .. "pen-up logs %d", st.touches, s_recs, erasers, x_recs, erased, st.logs))
print(format("ink commands %d, spans %d, publishes %d, region renders %d",
             st.ink, st.spans, st.publish, st.renders))
print(format("live: %d black px; replay: %d black px from %d visible strokes, %d bad lines",
             black(page), black(replayed), #rp.strokes, rp.bad_lines))
print(format("match: %s (%d px differ)", differ == 0 and "yes" or "NO", differ))

for _, w in ipairs({ { page, out_png }, { replayed, replay_png } }) do
    local ok, werr = Surface.write_png(w[1], w[2])
    if not ok then
        io.stderr:write(format("notebook-replay: cannot write %s: %s\n", w[2], werr))
        os.exit(2)
    end
end
print(format("wrote %s and %s", out_png:match("[^/]*$"), replay_png:match("[^/]*$")))

os.exit(differ == 0 and 0 or 1)
