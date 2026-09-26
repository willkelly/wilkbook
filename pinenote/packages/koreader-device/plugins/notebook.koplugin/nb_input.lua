--[[--
nb_input -- the notebook's recognizer: raw pen and touch evdev events in,
intent tables out.

Pure, like idlewasher_core: no KOReader, no ffi, no clock.  Every time it
sees is a realtime microsecond stamp, from an event (ev.t) or from the
glue's timer (on_timer's now_rt_us); both are CLOCK_REALTIME, and
KOReader's monotonic time never enters.  The controller feeds it the
events device.lua's consumer hook lifts out and acts on the intents.
pinenote/tools/koreader-input/test-notebook-input.lua covers every rule
below, and replays the 2026-09-26 Stylus captures when they are on disk.

Pen (w9013 Stylus), rules from those captures:

  * evdev sends an axis only when it changes, and the pen-down report
    carries BTN_TOUCH:1 BEFORE its new X/Y, so axes latch on their
    events, carry across reports, and a sample exists only at SYN_REPORT;
  * ink is gated on BTN_TOUCH alone: the rubber end reports pressure at
    distance 0 without contact;
  * losing or switching the tool while down ends the stroke with
    gap=true, and a stroke begins only in a report that carries
    BTN_TOUCH:1, so a proximity dropout (pen-1's Y=0 edge: 22-39 ms, back
    at P=4095) is two strokes, never a chord;
  * after SYN_DROPPED the rest of the report is discarded and the glue
    is asked for a key snapshot (pen_resync); the snapshot sets only
    proximity and tool, and the same BTN_TOUCH:1 rule keeps a lost
    pen-up from inking hover travel.

Touch (cyttsp5):

  * contacts follow kernel slots, and positions latch per SLOT: the input
    core does not resend an axis value a new contact shares with the
    slot's previous contact;
  * a frame commits at SYN_REPORT in kernel order: present contacts move,
    new ones start, then input_mt_sync_frame's auto-lifts land, so a
    finger landing in the frame another lifts in joins its session (a
    finger the cyttsp5 re-IDs mid-swipe turns no page rather than two);
  * a gesture is a session, from the first accepted contact down to the
    last one up.  A session that is one contact throughout can be a tap,
    long press or swipe (canvas) or a tap or drag (panel); a second
    contact cancels those, and the session can then only end as a
    multi_swipe;
  * multi-finger travel is the running sum of the MEAN displacement of
    the contacts present in consecutive frames.  The controller reports
    at most two contacts at once (nb_config's multi_min_fingers) and
    auto-lifts whichever it stops reporting, so fingers drop out and come
    back as new contacts; this sum adds no jump when they do;
  * a multi-finger swipe also needs multi_min_fingers contacts that each
    travelled half the swipe's minimum along it, in its direction.  With
    two fingers enough for an undo, a thumb resting on the glass beside
    one swiping finger has a mean that moves; it must not undo, and as
    two contacts it turns no page either (as before, when three fingers
    were needed and two did nothing);
  * palms: a contact that starts while the pen is in range, or less than
    palm_grace_us after it left, is invisible for its whole life.  The
    grace test is signed, because one batch is drained fd by fd and a
    contact stamped before the pen left can arrive after it.  A pen that
    arrives during a session vetoes it (the palm landed first) and ends
    a panel drag at zero velocity.  A palm can rest past longpress_us
    before the pen arrives, and its long press has then already fired
    by timer: the veto says so with long_press_vetoed;
  * a touch SYN_DROPPED kills the session the same way, and nothing
    fires until every contact has lifted (_touch_dropped says what the
    stream cannot recover).

Swipe distances are fractions of the panel's extent along the swipe's
dominant PHYSICAL axis.  For every logical-horizontal swipe (the only
ones that turn pages or undo) that is the logical width in all four
rotations, and it needs no rotation state here.

Intents are fresh tables, except that an event producing none returns
the shared Input.NONE: most events produce none (44 % of in-range pen
reports are hover, at 360 Hz).  Assigning into it raises an error, but
table.insert and rawset get past that guard, so callers only read what
they are given.
--]]

local G = require("nb_geom")

local Input = {}
Input.__index = Input

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT, SYN_DROPPED = 0, 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local ABS_TILT_X, ABS_TILT_Y = 26, 27
local BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH = 320, 321, 330
local ABS_MT_SLOT, ABS_MT_TRACKING_ID = 47, 57
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 53, 54

local raw_to_px = G.raw_to_px
local abs = math.abs

local NONE = setmetatable({}, {
    __newindex = function()
        error("nb_input: Input.NONE is shared; build a new table", 2)
    end,
})
Input.NONE = NONE

local function push(out, it)
    if out then
        out[#out + 1] = it
        return out
    end
    return { it }
end

function Input.new(cfg, hit)
    local self = setmetatable({}, Input)
    self.W, self.H = cfg.W, cfg.H
    self.abs_x_max, self.abs_y_max = cfg.abs_x_max, cfg.abs_y_max
    self.hit = hit
    self.palm_grace = cfg.palm_grace_us
    self.tap_max = cfg.tap_max_us
    self.tap_slop2 = cfg.tap_slop_px * cfg.tap_slop_px
    self.lp_us = cfg.longpress_us
    self.lp_slop2 = cfg.longpress_slop_px * cfg.longpress_slop_px
    self.swipe_max = cfg.swipe_max_us
    self.swipe_frac, self.swipe_ratio = cfg.swipe_min_frac, cfg.swipe_ratio
    self.multi_min = cfg.multi_min_fingers
    self.multi_frac, self.multi_ratio = cfg.multi_min_frac, cfg.multi_ratio
    self.multi_max = cfg.multi_max_us
    self.flick_window = cfg.flick_window_us
    self.activity_min = cfg.activity_min_interval_us

    -- Pen: key and axis latches, carried until an event changes them.
    self.key_pen, self.key_rubber, self.key_touch = false, false, false
    self.recent_tool = nil   -- whose BTN_TOOL_*:1 came last, if both are down
    self.touch_edge = false  -- this report carried BTN_TOUCH:1
    self.rawx, self.rawy = nil, nil
    self.p, self.tx, self.ty = 0, 0, 0
    -- Committed pen state.
    self.tool = nil          -- "pen" | "rubber" in range, nil out of range
    self.stroke = nil        -- the down stroke's tool, or nil
    self.pen_discard = false
    self.prox_out_t = nil

    -- Touch.  set_touch_slot replaces the initial slot: the kernel does
    -- not repeat ABS_MT_SLOT, so events for its current slot carry none.
    self.slot = 0
    self.slot_x, self.slot_y = {}, {}
    self.by_slot = {}
    self.live = {}           -- every contact down or pending, in start order
    self.any_down = false
    self.touch_blocked = false
    self.sess = nil

    self.last_activity_t = nil
    return self
end

function Input:pen_in_range()
    return self.tool ~= nil
end

function Input:any_touch_down()
    return self.any_down
end

function Input:set_touch_slot(n)
    self.slot = n
end

-- One limiter for pen and touch: both become the same synthetic
-- InputEvent.  A negative delta means realtime stepped back; re-basing
-- avoids going quiet until the clock catches up.
function Input:_activity(t, out)
    local last = self.last_activity_t
    if last and t >= last and t - last < self.activity_min then return out end
    self.last_activity_t = t
    return push(out, { k = "activity", t = t })
end

function Input:feed(ev)
    local src = ev.src
    if src == "pen" then return self:_pen(ev) end
    if src == "touch" then return self:_touch(ev) end
    return NONE -- penbtn: the ws8100 keys are swallowed, nothing more
end

------------------------------------------------------------------------
-- Pen
------------------------------------------------------------------------

function Input:_pen(ev)
    local ty, code, v = ev.type, ev.code, ev.value
    if ty == EV_SYN then
        if code == SYN_REPORT then
            if self.pen_discard then
                self.pen_discard = false
                return { { k = "pen_resync" } }
            end
            return self:_pen_commit(ev.t)
        elseif code == SYN_DROPPED then
            self.pen_discard = true
            self.touch_edge = false
            if self.stroke then return self:_end_stroke(ev.t, true) end
        end
        return NONE
    end
    if self.pen_discard then return NONE end
    if ty == EV_ABS then
        -- ev.value is device.lua's rounded px; ev.raw keeps the 11x finer
        -- digitizer unit.  Without it, invert the px scale so the journal
        -- still records raw units, at px precision.
        if code == ABS_X then
            self.rawx = ev.raw or v * self.abs_x_max / (self.W - 1)
        elseif code == ABS_Y then
            self.rawy = ev.raw or v * self.abs_y_max / (self.H - 1)
        elseif code == ABS_PRESSURE then
            self.p = v
        elseif code == ABS_TILT_X then
            self.tx = v
        elseif code == ABS_TILT_Y then
            self.ty = v
        end
    elseif ty == EV_KEY then
        if code == BTN_TOUCH then
            self.key_touch = v ~= 0
            if v ~= 0 then self.touch_edge = true end
        elseif code == BTN_TOOL_PEN then
            self.key_pen = v ~= 0
            if v ~= 0 then self.recent_tool = "pen" end
        elseif code == BTN_TOOL_RUBBER then
            self.key_rubber = v ~= 0
            if v ~= 0 then self.recent_tool = "rubber" end
        end
    end
    return NONE
end

function Input:_pen_commit(t)
    local tool
    if self.key_rubber and (not self.key_pen or self.recent_tool == "rubber") then
        tool = "rubber"
    elseif self.key_pen then
        tool = "pen"
    end
    local out
    local stroke = self.stroke
    if stroke then
        if tool ~= stroke then
            out = self:_end_stroke(t, true, out)
        elseif not self.key_touch then
            out = self:_end_stroke(t, false, out)
        end
    end
    if tool ~= self.tool then out = self:_set_tool(tool, t, out) end
    if self.stroke then
        out = push(out, self:_sample("stroke_point", t))
        out = self:_activity(t, out)
    elseif tool and self.touch_edge and self.key_touch
           and self.rawx and self.rawy then
        self.stroke = tool
        local it = self:_sample("stroke_begin", t)
        it.tool = tool
        out = push(out, it)
        out = self:_activity(t, out)
    end
    self.touch_edge = false
    return out or NONE
end

function Input:_sample(k, t)
    local rx, ry = self.rawx, self.rawy
    return {
        k = k, t = t,
        x = raw_to_px(rx, self.abs_x_max, self.W),
        y = raw_to_px(ry, self.abs_y_max, self.H),
        p = self.p, tx = self.tx, ty = self.ty,
        rawx = rx, rawy = ry,
    }
end

function Input:_end_stroke(t, gap, out)
    self.stroke = nil
    return push(out, { k = "stroke_end", t = t, gap = gap })
end

-- A switch without leaving range still reports prox off, then on: the
-- controller keys the tool, and its per-proximity work, on prox.
function Input:_set_tool(tool, t, out)
    local old = self.tool
    if old then out = push(out, { k = "prox", on = false, tool = old, t = t }) end
    self.tool = tool
    if tool then
        out = push(out, { k = "prox", on = true, tool = tool, t = t })
        local s = self.sess
        if s and not s.vetoed then
            s.vetoed = true
            if s.c.dragging then out = self:_end_drag(s.c, t, 0, 0, out) end
            -- The long press already fired, by timer, on a contact that
            -- is still down: a palm resting before the pen came into
            -- range.  Its panel is the controller's to take back.
            if s.long_pressed then
                out = push(out, { k = "long_press_vetoed", t = t })
            end
        end
    else
        self.prox_out_t = t
    end
    return out
end

-- The snapshot only restores proximity and tool.  A stroke needs a
-- BTN_TOUCH:1 seen after it, whatever snap.touching says, because the
-- snapshot has no position to start one from.
function Input:resync(snap, now)
    local tool
    if snap.prox then tool = snap.tool == "rubber" and "rubber" or "pen" end
    self.key_pen = tool == "pen"
    self.key_rubber = tool == "rubber"
    self.recent_tool = tool
    self.key_touch = snap.touching and true or false
    self.touch_edge = false
    local out
    if self.stroke then out = self:_end_stroke(now, true, out) end
    if tool ~= self.tool then out = self:_set_tool(tool, now, out) end
    return out or NONE
end

------------------------------------------------------------------------
-- Touch
------------------------------------------------------------------------

function Input:_touch(ev)
    local ty, code, v = ev.type, ev.code, ev.value
    if ty == EV_SYN then
        if code == SYN_REPORT then
            return self:_touch_commit(ev.t)
        elseif code == SYN_DROPPED then
            return self:_touch_dropped(ev.t)
        end
        return NONE
    end
    if ty ~= EV_ABS then return NONE end
    if code == ABS_MT_SLOT then
        self.slot = v
    elseif code == ABS_MT_POSITION_X then
        self.slot_x[self.slot] = v
    elseif code == ABS_MT_POSITION_Y then
        self.slot_y[self.slot] = v
    elseif code == ABS_MT_TRACKING_ID then
        local s = self.slot
        local by_slot = self.by_slot
        local c = by_slot[s]
        if c and c.id ~= v then
            c.gone = true
            by_slot[s] = nil
            c = nil
        end
        if v >= 0 and not c then
            c = { id = v, slot = s, new = true, d2 = 0 }
            by_slot[s] = c
            self.live[#self.live + 1] = c
        end
    end
    return NONE
end

-- Unlike the pen, touch gets no snapshot to resync from, so the cut
-- report is not discarded: its events, and the frames after it, go to
-- the last slot seen, which is the best guess there is, and a kept
-- ABS_MT_SLOT corrects it.  What was lost stays lost: a contact whose lift
-- fell in the gap stays down until its slot is reused, holding off
-- gestures and keeping any_touch_down true.  Recovering it needs a
-- snapshot the interface does not carry (EVIOCGABS(ABS_MT_SLOT) into
-- set_touch_slot, EVIOCGMTSLOTS for the live ids).  Getting here takes a
-- stall long enough to fill the touch node's 4096-event evdev buffer.
function Input:_touch_dropped(t)
    self.touch_blocked = true
    local s = self.sess
    local out
    if s then
        s.dead = true
        if s.c.dragging then out = self:_end_drag(s.c, t, 0, 0, out) end
    end
    return out or NONE
end

function Input:_touch_commit(t)
    local out
    local live = self.live
    local sx, sy = self.slot_x, self.slot_y
    local active = false

    -- Present contacts.
    local ddx, ddy, n = 0, 0, 0
    for i = 1, #live do
        local c = live[i]
        if not c.new and not c.gone then
            local px, py = c.x, c.y
            local x, y = sx[c.slot], sy[c.slot]
            if x and y and (x ~= px or y ~= py) then
                c.x, c.y = x, y
                -- A contact that landed without a position starts where
                -- it is first seen.
                if not c.sx then c.sx, c.sy = x, y end
                if c.accepted then
                    active = true
                    local s = self.sess
                    if s.total == 1 and c.x0 then
                        out = self:_single_move(s, c, t, out)
                    end
                end
            end
            if c.accepted and px then
                n = n + 1
                ddx, ddy = ddx + (c.x - px), ddy + (c.y - py)
            end
        end
    end
    if n > 0 then
        local s = self.sess
        s.mdx, s.mdy = s.mdx + ddx / n, s.mdy + ddy / n
    end

    -- New contacts.
    for i = 1, #live do
        local c = live[i]
        if c.new then
            c.new = false
            c.t0 = t
            local x, y = sx[c.slot], sy[c.slot]
            if x and y then c.x, c.y = x, y end
            local out_t = self.prox_out_t
            if self.tool or (out_t and t - out_t < self.palm_grace) then
                c.accepted = false
            else
                c.accepted = true
                active = true
                out = self:_join(c, t, out)
            end
        end
    end

    -- Lifts, compacting the live list in place.
    local j = 0
    for i = 1, #live do
        local c = live[i]
        if c.gone then
            if c.accepted then
                local s = self.sess
                s.n = s.n - 1
            end
        else
            j = j + 1
            live[j] = c
        end
    end
    for i = #live, j + 1, -1 do live[i] = nil end

    local s = self.sess
    if s then
        if s.n > s.peak then s.peak = s.n end
        if s.arm then
            -- Only a contact still alone at the end of its first frame
            -- can become a long press: fingers landing together cannot.
            s.arm = false
            if s.total == 1 and s.n == 1 then
                out = push(out, { k = "timer", delay_us = self.lp_us })
            end
        end
        if active and not s.vetoed then out = self:_activity(t, out) end
        if s.n == 0 then
            self.sess = nil
            if not s.dead and not s.vetoed then
                if s.total == 1 then
                    out = self:_single_end(s.c, t, out)
                else
                    out = self:_multi_end(s, t, out)
                end
            end
        end
    end

    local down = j > 0
    if not down then self.touch_blocked = false end
    if down ~= self.any_down then
        self.any_down = down
        out = push(out, { k = "touch_down_changed", any_down = down })
    end
    return out or NONE
end

-- An accepted contact starts: it opens a session or joins the open one.
-- A slot's first contact after open has no start point if it landed on
-- the column or row the slot already held (the kernel skips an unchanged
-- axis); it still counts, but can make no single-contact gesture.
function Input:_join(c, t, out)
    c.sx, c.sy = c.x, c.y
    local s = self.sess
    if not s then
        s = { t0 = t, n = 0, total = 0, peak = 0, mdx = 0, mdy = 0, c = c,
              dead = self.touch_blocked, vetoed = false, contacts = {} }
        self.sess = s
        if c.x then
            c.x0, c.y0 = c.x, c.y
            c.target = self.hit and self.hit(c.x, c.y) or "canvas"
            if c.target == "panel" then
                c.trail = { { t = t, x = c.x, y = c.y } }
            else
                s.arm = not s.dead -- the commit's end decides
            end
        end
    end
    s.n = s.n + 1
    s.total = s.total + 1
    s.contacts[s.total] = c
    if s.total == 2 then
        local first = s.c
        if first.dragging then out = self:_end_drag(first, t, 0, 0, out) end
    end
    return out
end

function Input:_single_move(s, c, t, out)
    if s.dead or s.vetoed or c.done then return out end
    local dx, dy = c.x - c.x0, c.y - c.y0
    local d2 = dx * dx + dy * dy
    if d2 > c.d2 then c.d2 = d2 end
    if c.target ~= "panel" then return out end
    local trail = c.trail
    trail[#trail + 1] = { t = t, x = c.x, y = c.y }
    -- Keep one sample at or before the window's start: the flick is
    -- measured from where the finger was when the window opened.
    while trail[2] and trail[2].t <= t - self.flick_window do
        table.remove(trail, 1)
    end
    if c.dragging then
        return push(out, { k = "drag_move", x = c.x, y = c.y, t = t })
    end
    if c.d2 > self.tap_slop2 then
        -- Begin at the contact's start point, so the panel moves by the
        -- whole finger travel rather than lagging it by the slop.
        c.dragging = true
        out = push(out, { k = "drag_begin", x = c.x0, y = c.y0, t = t })
        out = push(out, { k = "drag_move", x = c.x, y = c.y, t = t })
    end
    return out
end

function Input:_end_drag(c, t, vx, vy, out)
    c.dragging = false
    c.done = true
    return push(out, { k = "drag_end", x = c.x, y = c.y, t = t, vx = vx, vy = vy })
end

-- Velocity over the last flick_window_us, the position being the last
-- reported one at any instant: a finger that stops, then lifts, has not
-- flicked.
function Input:_flick(c, t)
    local trail = c.trail
    local ws = t - self.flick_window
    local base = trail[1]
    for i = 2, #trail do
        if trail[i].t > ws then break end
        base = trail[i]
    end
    local last = trail[#trail]
    local dt = t - (base.t > ws and base.t or ws)
    if dt <= 0 then return 0, 0 end
    return (last.x - base.x) * 1e6 / dt, (last.y - base.y) * 1e6 / dt
end

function Input:_single_end(c, t, out)
    if c.dragging then
        local vx, vy = self:_flick(c, t)
        return self:_end_drag(c, t, vx, vy, out)
    end
    if c.done or not c.x0 then return out end
    local dur = t - c.t0
    if dur < 0 then dur = 0 end
    if dur <= self.tap_max and c.d2 <= self.tap_slop2 then
        return push(out, { k = "tap", x = c.x0, y = c.y0, t = t, target = c.target })
    end
    if c.target ~= "canvas" then return out end
    -- The timer is on the monotonic UI loop; a busy loop can run it after
    -- the lift, when the event times still say the press was long.
    if dur >= self.lp_us and c.d2 <= self.lp_slop2 then
        return push(out, { k = "long_press", x = c.x, y = c.y, t = t })
    end
    if dur > self.swipe_max then return out end
    local dx, dy = c.x - c.x0, c.y - c.y0
    if self:_is_swipe(dx, dy, self.swipe_frac, self.swipe_ratio) then
        return push(out, { k = "swipe", dx = dx, dy = dy, t = t })
    end
    return out
end

function Input:_is_swipe(dx, dy, frac, ratio)
    local ax, ay = abs(dx), abs(dy)
    local along, across, extent
    if ax >= ay then
        along, across, extent = ax, ay, self.W
    else
        along, across, extent = ay, ax, self.H
    end
    return along >= frac * extent and along >= ratio * across
end

function Input:_multi_end(s, t, out)
    local dur = t - s.t0
    if s.peak < self.multi_min or dur > self.multi_max then return out end
    local mdx, mdy = s.mdx, s.mdy
    if not self:_is_swipe(mdx, mdy, self.multi_frac, self.multi_ratio) then
        return out
    end
    -- The fingers that travelled: half the swipe's minimum along its
    -- dominant axis, the way the mean went.  A contact the controller cut
    -- short and brought back is two contacts here, each with its share.
    local along_x = abs(mdx) >= abs(mdy)
    local need = 0.5 * self.multi_frac * (along_x and self.W or self.H)
    local sign = along_x and mdx or mdy
    local moved = 0
    for _, c in ipairs(s.contacts) do
        if c.sx then
            local d = along_x and (c.x - c.sx) or (c.y - c.sy)
            if d * sign > 0 and abs(d) >= need then moved = moved + 1 end
        end
    end
    if moved < self.multi_min then return out end
    return push(out, { k = "multi_swipe", dx = mdx, dy = mdy,
                       fingers = s.peak, t = t })
end

function Input:on_timer(now)
    local s = self.sess
    if not s or s.total ~= 1 or s.dead or s.vetoed then return NONE end
    local c = s.c
    if c.done or c.target ~= "canvas" or c.d2 > self.lp_slop2 then return NONE end
    local elapsed = now - c.t0
    if elapsed < self.lp_us then
        if elapsed < 0 then elapsed = 0 end
        return { { k = "timer", delay_us = self.lp_us - elapsed } }
    end
    c.done = true
    s.long_pressed = true
    return { { k = "long_press", x = c.x, y = c.y, t = now } }
end

return Input
