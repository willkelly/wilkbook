--[[--
Slot identity guard for KOReader's multitouch frames.

KOReader's Input keeps one persistent table per MT slot (ev_slots) and,
per the MT protocol B contract, only receives the fields that CHANGED in
a frame.  Its gesture detector assumes every slot it is fed is a known
contact: a tracking id, and x/y.  Two upstream "safety nets"
(GestureDetector:newContact and Contact:setState) paper over a slot that
arrives without those by deep-copying whatever the slot table holds into
the contact's initial_tev -- and Contact:getPath then does arithmetic on
initial_tev.x.  If the copy had no x, KOReader dies:

    gesturedetector.lua:325: attempt to perform arithmetic on field 'x'
    (a nil value)

On the PineNote this happened on glass (2026-09-02) during pinch-to-font
-size, and reproduces deterministically offline
(pinenote/tools/koreader-input/test-slotguard.lua).  The mechanism is
upstream's own: a pinch emits on the FIRST finger's lift, ReaderRolling
re-renders for the new size and calls Input:inhibitInput(true) -- the
still-down finger's frames are dropped -- then inhibitInput(false) calls
Input:resetState(), which wipes every slot table and forgets every
contact.  The finger still on the glass then reports delta-only frames
(the kernel re-sends neither its tracking id nor an unchanged axis) into
a fresh, empty table: a ghost contact with no id and no position.  The
next finger to land pairs with the ghost as its two-finger buddy, the
safety nets copy the positionless table, and the next two-finger pan
crashes.  The "recorded an initial_tev out of order" warnings that
precede every such crash are the same defect, survived.

This guard closes the crash independently of upstream: at each
SYN_REPORT, before the frame reaches the detector, any slot whose table
has no tracking id, or a live id but no x/y yet, is withheld from that
frame.  The slot's own table keeps accumulating, so the moment the kernel
has told us who and where (a new contact's TRACKING_ID always arrives
with its position; a reset survivor is complete again as soon as both
axes have moved, or on its lift), it is fed as a proper contact.  Lifts
(id == -1) always pass, positioned or not: upstream drops an unknown
lifted slot cleanly in initialState.  Well-formed frames are untouched,
which test-slotguard.lua pins with the mixedrouter suite's own
two-finger stream.

What this does NOT do: restore the forgotten contact.  After a reset the
still-down finger is invisible until it is complete again; that is the
behaviour upstream chose with resetState(), minus the crash.  The
faithful fix -- re-reading each slot's state from the kernel with
EVIOCGMTSLOTS after every reset -- is the follow-up recorded in
doc/upstream-register.md alongside the upstream report.
--]]

local EV_SYN = 0
local SYN_REPORT = 0

local SlotGuard = {}

-- A slot the gesture detector may safely be fed this frame.
local function complete(slot_data)
    local id = slot_data.id
    if id == nil then return false end          -- identity unknown (delta-only frame after a reset)
    if id == -1 then return true end            -- a lift: upstream handles an unknown lifted slot
    return slot_data.x ~= nil and slot_data.y ~= nil
end

-- Returns the number of slots withheld from the frame (for tests/logs).
function SlotGuard.filter_frame(input)
    local slots = input.MTSlots
    if not slots or #slots == 0 then return 0 end
    local kept, withheld = {}, 0
    for _, slot_data in ipairs(slots) do
        if complete(slot_data) then
            kept[#kept + 1] = slot_data
        else
            withheld = withheld + 1
            -- Keep active_slots consistent so a later event in the SAME
            -- frame cannot re-add the slot; newFrame() clears both after
            -- the detector has been fed.
            if input.active_slots then input.active_slots[slot_data.slot] = nil end
        end
    end
    if withheld > 0 then input.MTSlots = kept end
    return withheld
end

function SlotGuard.install(input)
    local wrapped = input.handleTouchEv
    input.handleTouchEv = function(self, ev)
        if ev.type == EV_SYN and ev.code == SYN_REPORT then
            SlotGuard.filter_frame(self)
        end
        return wrapped(self, ev)
    end
    input._wilkbook_slotguard = true
end

return SlotGuard
