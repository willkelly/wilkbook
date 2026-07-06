--[[--
Source-aware slot routing for KOReader's mixed pen+touch input path.

KOReader's Input keeps ONE global cur_slot for all devices.  With
wacom_protocol, BTN_TOOL_PEN:1 (pen enters hover range — no contact
needed) parks cur_slot on the dedicated pen slot and nothing moves it
back until BTN_TOOL_PEN:0 or an explicit ABS_MT_SLOT.  The kernel input
core deduplicates ABS_MT_SLOT, so a single-finger touchscreen session
(always slot 0) never emits one — and while the pen hovers, every
finger tap's ABS_MT_TRACKING_ID/ABS_MT_POSITION_* land in the PEN slot,
where interleaved pen-hover coordinates rewrite the contact mid-gesture.
The tap becomes a swipe along the fixed finger->pen bearing: on the
PineNote this made every tap on a quickstart TOC link "navigate" one
page forward to the same wrong page (hardware-observed 2026-07-05,
root-caused offline; the whole chain is in doc/status.md).

The backend tags every event with src = originating device node, so the
ambiguity is fixable outside upstream: route each EV_ABS event to its
OWN device's slot by synthesizing the ABS_MT_SLOT switch the kernel
suppressed, using upstream's own setupSlotData semantics.  Symmetric
guards keep the pen working while fingers interleave:
 * touchscreen MT events go to the touchscreen's kernel slot (tracked
   here, since the kernel's dedup hides it);
 * pen ABS_X/ABS_Y go to the pen slot (otherwise a finger interleave
   would strand hover tracking on slot 0 until the pen re-entered
   proximity);
 * pen BTN_TOUCH is re-routed before the key handler runs, because
   upstream gates it on the CURRENT slot's tool being PEN.

The upstream slot-4-collision wart (pen_slot = main_finger_slot + 4
collides with a real 5th-finger slot) is unchanged — this only restores
the routing upstream already assumes.  Worth reporting upstream: the
src-blind cur_slot bites every wacom_protocol + multitouch device.
--]]

-- Stable kernel input ABI constants (kept local so the module is
-- loadable in a bare host harness without KOReader's ffi cdefs).
local EV_KEY = 1
local EV_ABS = 3
local ABS_X = 0x00
local ABS_Y = 0x01
local ABS_MT_SLOT = 0x2f
local ABS_MT_POSITION_X = 0x35
local ABS_MT_POSITION_Y = 0x36
local ABS_MT_TRACKING_ID = 0x39
local BTN_TOUCH = 0x14a

local MixedRouter = {}

function MixedRouter.install(input, pen_src, touch_src)
    -- The touchscreen's own kernel slot state.  Protocol B defaults to
    -- slot 0 and only reports changes, so this mirrors what the kernel
    -- suppressed.
    local touch_slot = 0

    local function switch_slot(handler, ev, slot)
        -- Synthesize the ABS_MT_SLOT event the kernel deduplicated;
        -- upstream's setupSlotData does the rest (adds the slot to the
        -- current frame, or just re-points cur_slot).
        handler(input, {
            type = EV_ABS,
            code = ABS_MT_SLOT,
            value = slot,
            time = ev.time,
            src = ev.src,
        })
    end

    local wrapped_touch = input.handleTouchEv
    input.handleTouchEv = function(self, ev)
        if ev.type == EV_ABS then
            if ev.src == touch_src then
                if ev.code == ABS_MT_SLOT then
                    touch_slot = ev.value
                elseif (ev.code == ABS_MT_TRACKING_ID
                        or ev.code == ABS_MT_POSITION_X
                        or ev.code == ABS_MT_POSITION_Y)
                       and self.cur_slot ~= touch_slot then
                    switch_slot(wrapped_touch, ev, touch_slot)
                end
            elseif ev.src == pen_src
                   and (ev.code == ABS_X or ev.code == ABS_Y)
                   and self.cur_slot ~= self.pen_slot then
                switch_slot(wrapped_touch, ev, self.pen_slot)
            end
        end
        return wrapped_touch(self, ev)
    end

    local wrapped_key = input.handleKeyBoardEv
    input.handleKeyBoardEv = function(self, ev)
        -- Pen tip contact: upstream only honors it when the CURRENT
        -- slot's tool is PEN (it assumes cur_slot is still parked on
        -- the pen slot from BTN_TOOL_PEN).  Restore that before it
        -- looks.  BTN_TOOL_PEN itself self-routes via setupSlotData.
        if ev.src == pen_src and ev.type == EV_KEY
           and ev.code == BTN_TOUCH
           and self.cur_slot ~= self.pen_slot then
            self:setupSlotData(self.pen_slot)
        end
        return wrapped_key(self, ev)
    end
end

return MixedRouter
