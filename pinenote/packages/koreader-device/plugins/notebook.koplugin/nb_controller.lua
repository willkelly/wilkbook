--[[--
nb_controller -- the notebook session: raw pen and touch events and the
glue's lifecycle calls in, an ordered list of commands out.

Pure, like the modules it composes (nb_input, nb_brush, nb_panel,
nb_geom, and nb_journal's codec and replay; never its Store, whose IO is
the glue's): no KOReader, no ffi, no io, and the only clock is the
injected now_rt_us.  main.lua executes the commands in order.  Every
call returns a new array, possibly empty, that the glue may keep.
pinenote/tools/koreader-input/test-notebook-controller.lua drives it
with scripted pen and touch sessions and replays the 2026-09-26 Stylus
captures through it.

Commands (physical px unless noted; the vocabulary the glue codes to):

  arm {rects}          set the hint plane: rects = { {x,y,w,h,hint} },
                       the canvas at 0x00 first, then the open panel's
                       physical rect at 0x20 (a later rect wins)
  disarm               return the plane to the reading default
  ink {spans, comp, pat, dens}
                       spans = {y, x0, x1, ...}, inclusive and clipped;
                       into the page buffer and the framebuffer alias
  publish_ink          Device:publishNow(), once per pen report that drew
  append {page, line}  nb:append(page, line)
  fsync {page}         nb:fsync(page).  On the first append or fsync
                       failure in a list, run the rest of the list less
                       its append, arm, ink and publish_ink commands,
                       then call c:io_error(err, failed_cmd) and run what
                       it returns
  load_page {page}     nb:page_lines + J.replay(lines, live cfg), then
                       c:page_loaded(page, replayed) (or nil, err)
  render_page {page, strokes, region}
                       rebuild the page buffer from strokes; only pixels
                       in region (nil: all) can differ from before
  repaint {region}     setDirty on the notebook window (nil: all of it)
  panel {layout}       show or update the panel at layout (LOGICAL
                       px, nb_panel's), or hide it when layout is nil
  washer_charge {n}    IdleWasher:chargePageTurn(n or 1); page turns made
                       with the pen nearby wait for its leave
  washer_debt {n}      IdleWasher:chargeDebt(n): n repaints that leave a
                       ghost, since the last washer_debt (the ghost debt
                       rule below)
  publish              Device:publishNow() for a paint the glue made in
                       place (the page where the panel was), not ink: never
                       skipped after a failed write, never timed; then
                       c:published(now_rt_us) and run what it returns
  wash                 one full-panel wash that repaints nothing
                       (UIManager:setDirty(nil, "full")); a disarm comes
                       first
  activity             one synthetic InputEvent (already rate-limited)
  schedule {delay_us}  call c:on_timer(now_rt_us) after delay_us.  One
                       timer: a newer schedule replaces a pending one,
                       and the controller always asks for the sooner of
                       what it and nb_input wait for
  resync_pen           take a Stylus key snapshot, call c:resync(snap, now)
  rotation_hold {on}   the rotation-hold predicate's answer
  save_prefs {prefs}   Store:save_prefs(prefs): only the settings the user
                       chose on the panel, plus the reopen place
  log {line}           one logger line
  toast {text}         a timed message
  new_notebook, open_list, close_notebook
                       UI actions, through UIManager:nextTick

Why the rules below are what they are:

  * The DU rectangle is armed when the pen comes into range with ink
    live, or when ink turns live with the pen in range, and otherwise
    lazily, in the same call and ahead of the first ink command that
    needs it.  Hints are sampled when the damage worker blits, after the
    publish returns, so an arm must land before the ink it governs, and
    a touch-driven paint (a turn, the panel) must not be blitted under
    it: palm rejection keeps touch out while the pen is in range, so
    arming at proximity keeps the two apart.  Every page render, panel
    change and undo/redo repaint is preceded by a disarm, emitted once
    per command list.
  * Ink goes to both surfaces as the pen reports it, with the style the
    stroke will be recorded with, a dot for the first sample and a
    segment per later one: exactly what Brush.render draws from the
    replayed record, so a reread page is the page the pen drew.
  * The tip as an area eraser keeps the pen's pressure window
    (cfg.pen_p_lo..pen_p_hi): the rubber's 180..880 window would pin the
    tip, whose median pressure is ~2716, at the eraser's widest.
  * A stroke is appended at pen-up in one write, and fsynced only when
    the pen leaves range, at suspend and at close, or straight after a
    touch-driven append (undo, redo), when the pen is out of range by
    construction.  A blocking fsync with the pen in range could overflow
    the Stylus node's ~100 ms evdev buffer.  Only pages appended to since
    their last fsync are named.
  * A leave is a proximity-out that lasts cfg.prox_leave_us.  The
    digitizer drops proximity for 22-44 ms at the panel's Y=0 edge and
    in hover flicker with the nib still on the glass, so a prox-out only
    schedules the leave, and a prox-in inside the window cancels it (a
    tool switch inside one report is not even a prox-out).  The leave
    runs the fsync, the deferred renders and panel update, and releases
    the rotation hold.  A dropout still splits the stroke, with its gap
    flag: the half-strokes are two records.
  * Nothing turns the page while the pen is down, because a stroke
    belongs to the page it started on: a page that finishes loading
    under a down pen is shown at pen-up, after the stroke is appended to
    the page it was drawn on.
  * The stroke eraser picks whole ink strokes by touch: a fixed reach
    (the eraser's rmin, the lightest touch) keeps what it picks
    predictable.  Area-eraser strokes are never picked, because removing
    one would bring back the ink it erased.  Picked strokes are whited
    out live.  The page render that restores what they overlapped is
    page-scale work, so while the pen is in range it waits for the leave,
    like the fsync; ink going dead, suspend and close run it at once.
  * A long press that fired on a contact still down when the pen arrives
    was a palm resting before the pen came into range, not a press:
    nb_input says so (long_press_vetoed), and the panel it opened closes.
  * After any append, fsync or encode failure nothing is inked or
    appended again by this controller: a retried fsync on a new fd can
    report success after EIO, so no later success proves the page is
    whole.  Reading and turning pages still work.  Build a new
    controller for a fresh session once the glue has re-probed the store.
    The screen shows no ink the journal will never hold: a stroke the
    failure cuts off is rendered away, and so is the record whose own
    append failed, which was applied to the page in memory when its
    append was emitted and is taken back out.  A list can hold ink after
    an append (a tool switch whose report also re-presses), so the glue
    skips a list's writes and ink after its first failure, and reports
    the failure only at the end of the list, where the rendering that
    takes the record back comes after any rendering the list held.
  * The panel's hit test reads the state of its last layout(), so every
    change of what it shows is laid out at once, and shown at once, the
    pen's own ink included (Undo turning on, Redo off, at its pen-up):
    the pen taps the panel from a hover, so the panel on the glass must
    be the one its tap hits.  That costs one panel repaint, and a re-arm
    at the next stroke, only when Undo or Redo changes.  Suspend and
    close repaint nothing, so an update they cut short waits; resume or
    the leave shows it.
  * The pen on the open panel.  A pen contact that starts inside the
    panel's rect is a panel contact for its whole life: it never inks,
    erases or journals, wherever it goes.  If the tip lifts within
    tap_max_us and tap_slop_px of where it landed, in the same contact
    (no gap), it is a tap on the item it landed on, exactly as a finger
    tap.  A contact a proximity dropout cut, at either end, is not a
    tap: nb_input reports its rest as a new stroke, so a stroke from the
    canvas cut over a button would otherwise press it at the lift.  (That
    rest began on the panel, so it inks nothing: a dropout over the panel
    costs the stroke its tail.) A panel-owned tail stays panel-owned even
    when a dropout brings it back on the canvas. Anything else it does is
    ignored: a pen drag from the panel, even from the title bar, moves nothing (the
    finger drags the panel), and the rubber end activates nothing.  The
    pen never opens the panel and never turns a page by swiping; a tap on
    Prev or Next turns it after the tip has lifted.  A contact that
    starts outside the panel inks as ever, clipped at the panel on the
    glass.
  * Ghost debt.  An area erase, a stroke erase that removed strokes, an
    undo or redo that re-rendered something, and the panel closing each
    leave a ghost of what was there, and none of them is a page turn, so
    the idle washer counted none of them: writing and erasing on one page
    never reached its debt_min.  Each now counts one unit of the
    washer's debt (washer_debt; IdleWasher:chargeDebt accumulates and never
    washes by itself).  Ink is not charged: what the operator saw linger
    on glass (generation 22) was erased ink and the page before, not new
    ink.  Units wait while the pen is here (in range, or its leave not yet
    run) and go out as one command at the leave, the fsync's moment, or at
    suspend and close; so no charge is ever emitted with a stroke down.  A finger's action (palm
    rejection keeps the pen out of range for it) charges in its own list,
    at the touch's end.  The Refresh button charges nothing, since it
    washes. The shell retires the washer debt only after the queued full
    refresh's successful ioctl acknowledgement, preserving newer charges.
    Page-turn charges wait for the leave too, but may bundle a wash there;
    close, suspend and a pending explicit Refresh accumulate them only.
  * The Refresh button.  It closes the panel; the glue paints the page
    where the panel was and publishes that paint (publish), then says when
    it did (published): the list is built before the glue paints, so a
    wait counted from the controller's own clock would end short of the
    publish by the paint's time.  The wash
    comes cfg.refresh_settle_us later, because hrdl's direct driver starts
    a GLOBAL_REFRESH without flushing damage in flight, and a page render,
    repaint, panel change or rotation during the wait starts the wait
    again.  It
    never comes with the pen in range: a pen that tapped Refresh is still
    hovering, and a pen that arrives during the wait holds it, so the wait
    starts again at the pen's leave (deferred, not cancelled, or a pen tap
    could never refresh).  A page shown during the wait drops the wash,
    since a wash must not ride a page turn, and so does anything that
    takes the screen from the notebook: ink going dead (a widget on top),
    suspend and close.
--]]

local Brush = require("nb_brush")
local G = require("nb_geom")
local Input = require("nb_input")
local J = require("nb_journal")
local Panel = require("nb_panel")

local Ctl = {}
Ctl.__index = Ctl

local floor, abs = math.floor, math.abs
local format, concat, sort = string.format, table.concat, table.sort

local HINT_DU = 0x00      -- Y1 | THRESHOLD: the live-ink rectangle
local HINT_PANEL = 0x20   -- the plane default: the panel keeps its grays

-- Action ids are per page and only a crafted file gets near this; past
-- it new actions are refused rather than encoded, with one toast.
local MAX_ACTION = 2^31
-- Page numbers stay exact integers well inside the journal's 2^53.
local MAX_PAGE = 2^52

local function set_of(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end

local VALID = {
    brush = set_of(Brush.IDS),
    size = set_of({ "S", "M", "L" }),
    mode = set_of({ "write", "erase", "stroke_erase" }),
    rubber = set_of({ "area", "stroke" }),
}
-- Ballpoint M, not the fixed-width Fine: at the median contact pressure
-- (~2716 raw) it draws 5 px, ~0.56 mm, the width of the 2026-09-26
-- scribble.lua brush the operator compared the notebook with, and
-- pressure widens or thins it (nb_brush).  A default reaches only users
-- who never chose on the panel (clean_prefs below).
local DEFAULT = { brush = "ballpoint", size = "M", mode = "write",
                  rubber = "area" }
local PREF_KEYS = { "brush", "size", "mode", "rubber" }

-- note_timing kinds, in log order.
local TIMING_KINDS = { "stamp", "publish", "append", "fsync" }
local TIMING_SET = set_of(TIMING_KINDS)

local function int(v)
    return format("%d", floor(v + 0.5))
end

-- render_page carries a snapshot: J.apply appends a new stroke to
-- page.strokes in place, and the glue may keep the command.
local function snapshot(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

-- Span collector for nb_brush's emit callback.  One collector serves
-- every stamp, so a segment costs no closure; the controller never
-- re-enters itself, so the shared state cannot interleave.
local col_spans, col_n, col_dens
local function collect(y, x0, x1, dens)
    local n = col_n
    col_spans[n + 1], col_spans[n + 2], col_spans[n + 3] = y, x0, x1
    col_n = n + 3
    col_dens = dens
end

------------------------------------------------------------------------
-- Construction and lifecycle
------------------------------------------------------------------------

-- Prefs arrive from Store:load_prefs, and leave through save_prefs,
-- whose encoder raises on anything outside its schema; keep only values
-- it accepts, so a hand-edited prefs.json cannot take the glue down.
-- The settings are sparse overrides (doc/configuration.md, section 2):
-- only what the user chose on the panel is kept, and an absent one reads
-- as today's DEFAULT, so a changed default reaches everyone who never
-- chose.  A value this build does not know (a brush a later build
-- removed) is dropped and reads as the default.
local function clean_prefs(p)
    p = type(p) == "table" and p or {}
    local out = {}
    for _, key in ipairs(PREF_KEYS) do
        if VALID[key][p[key]] then out[key] = p[key] end
    end
    if J.is_id(p.last_id) then out.last_id = p.last_id end
    if type(p.last_page) == "table" then
        local lp = {}
        for id, n in pairs(p.last_page) do
            if J.is_id(id) and type(n) == "number" and n == floor(n)
               and abs(n) <= MAX_PAGE then
                lp[id] = n
            end
        end
        out.last_page = lp
    end
    return out
end

--- Ctl.new{cfg=, prefs=, rotation_mode=, now_rt_us=fn}.  cfg is the live
-- config (Screen.bb W/H, EVIOCGABS ranges); the replayed pages handed to
-- open and page_loaded must come from J.replay with the same cfg.
function Ctl.new(o)
    local self = setmetatable({}, Ctl)
    local cfg = assert(o.cfg, "nb_controller: cfg is required")
    self.cfg = cfg
    self.W, self.H = cfg.W, cfg.H
    self.now_rt_us = assert(o.now_rt_us, "nb_controller: now_rt_us is required")
    self.prefs = clean_prefs(o.prefs)
    local mode = o.rotation_mode
    if mode ~= 0 and mode ~= 1 and mode ~= 2 and mode ~= 3 then mode = 0 end
    self.mode = mode
    self.r = G.bb_rotation(mode)
    self.pn = Panel.new(cfg)
    self.pn:set_screen(G.logical_size(self.r, self.W, self.H))
    self.sx_r = Brush.style(Brush.IDS[1], "M", "eraser", cfg).rmin
    self.hit = function(px, py) return self:_hit_test(px, py) end
    self.opened = false
    self.ink_live = false
    self.suspended = false
    self.failed = false
    self.timing = {}
    self.drops = 0
    self.armed = false
    self.held = false
    self.leave_us = cfg.prox_leave_us or 0
    self.leave_at = nil      -- when a pending leave runs (realtime us)
    self.erased_box = nil    -- a stroke erase's render, waiting for the leave
    self.ghost_debt = 0      -- units not yet charged to the washer
    self.turn_debt = 0       -- page turns made by the hovering panel pen
    self.wash_us = cfg.refresh_settle_us or 0
    self.wash_wanted = false -- Refresh was tapped and its wash has not run
    self.wash_at = nil       -- when it may run (realtime us); nil while the
                             -- pen is here, and the leave sets it
    return self
end

-- A setting as it applies now: the user's choice, else the default.
function Ctl:_pref(key)
    local v = self.prefs[key]
    if v == nil then return DEFAULT[key] end
    return v
end

--- nb_info = {id=, title=}; page = J.replay(nb:page_lines(page_n), cfg).
-- The controller applies its own records to page, so the glue must not
-- share it.  After open: set_touch_slot, resync, set_ink_live.  Open
-- does not flush a notebook already open: the glue closes it first
-- (main.lua's NotebookWindow:_switch), while its nb still takes close's
-- fsyncs.
function Ctl:open(nb_info, page_n, page)
    local out = {}
    self.opened = true
    self.suspended = false
    self.nb = type(nb_info) == "table" and nb_info or {}
    self.page_n, self.page = page_n, page or J.replay({}, self.cfg)
    self.loading, self.pending_load = nil, nil
    self.stroke, self.pen_down, self.pen_panel = nil, false, nil
    self.cut_t, self.cut_panel = nil, nil
    -- The new Input knows no pen until the glue's resync.
    self.in_range = false
    self.leave_at, self.erased_box = nil, nil
    self:_drop_wash()
    self:_hold(false, out)
    self.dirty = {}
    self.last_append = nil
    self.last_written = nil
    self.full_warned = false
    self.panel_drag, self.panel_state, self.L = nil, nil, nil
    self.panel_stale = false
    self.inp = Input.new(self.cfg, self.hit)
    self.pn:close()
    self:_panel_sync(out, true)
    -- The glue resets the hint owner before open, so this is a no-op
    -- there; it keeps "a disarm before every render" true for any glue,
    -- and clears the glue's remembered arm.
    self.armed, self._disarmed_out = false, nil
    self:_disarm(out)
    out[#out + 1] = { op = "render_page", page = page_n,
                      strokes = snapshot(self.page.strokes) }
    out[#out + 1] = { op = "repaint" }
    local id = self.nb.id
    if J.is_id(id) and self.prefs.last_id ~= id then
        self.prefs.last_id = id
        self:_emit_prefs(out)
    end
    return out
end

--- The kernel's current ABS_MT_SLOT (absinfo's third value), after open.
function Ctl:set_touch_slot(n)
    if self.inp then self.inp:set_touch_slot(n) end
    return {}
end

function Ctl:close()
    local out = {}
    if not self.opened then return out end
    if self.stroke then self:_finish(true, out, false) end
    self.pen_panel = nil
    self.leave_at = nil
    self:_drop_wash()
    self:_flush(out)
    self:_render_erased(out, false)
    self:_disarm(out)
    self:_hold(false, out)
    self:_save_place(out)
    self:_flush_prefs(out)
    self:_flush_debt(out)
    self.pn:close()
    self.panel_drag = nil
    self.loading, self.pending_load = nil, nil
    -- Nothing of this session's pen or predicate carries into the next
    -- open: its Input starts out of range, and ink waits for the glue's
    -- set_ink_live, so a resync at open cannot arm on a stale answer.
    self.in_range = false
    self.ink_live = false
    self.opened = false
    return out
end

-- The screensaver is up: nothing is repainted, and a panel update still
-- waiting stays pending for resume.  A leave the pen had started runs
-- now, so the hold does not outlast the sleep.
function Ctl:suspend()
    local out = {}
    if not self.opened then return out end
    if self.stroke then self:_finish(true, out, false) end
    -- A panel contact the sleep cut short taps nothing.
    self.pen_panel = nil
    self.suspended = true
    self:_drop_wash()
    if self.leave_at then
        self:_leave(out, false)
    else
        self:_flush(out)
        self:_render_erased(out, false)
    end
    self:_disarm(out)
    self:_save_place(out)
    self:_flush_prefs(out)
    self:_flush_debt(out)
    return out
end

--- snap = {prox=, tool=, touching=} from the Stylus keys: the pen may have
-- left, arrived or lifted while the device slept.
function Ctl:resume(snap)
    local out = {}
    if not self.opened then return out end
    self.suspended = false
    if snap then self:_run(self.inp:resync(snap, self.now_rt_us()), out) end
    self:_maybe_arm(out)
    -- A panel update suspend kept, with no leave left to show it.
    if self.panel_stale and not self.in_range and not self.leave_at then
        self.panel_stale = false
        if self.pn:is_open() then self:_panel_emit(out) end
    end
    return out
end

--- live: the notebook is topmost, the menu closed, the device awake.
-- snap, when given, resyncs the pen first.
function Ctl:set_ink_live(live, snap)
    local out = {}
    live = live and true or false
    if not self.opened then
        self.ink_live = live
        return out
    end
    if snap then self:_run(self.inp:resync(snap, self.now_rt_us()), out) end
    if live == self.ink_live then return out end
    self.ink_live = live
    if live then
        self:_maybe_arm(out)
    else
        -- What was inked stays in the page buffer, so it is recorded;
        -- the rest of this pen-down is dropped.  The widget now on top
        -- repaints the window when it goes, so a stroke erase's render
        -- cannot wait for the pen.
        if self.stroke then self:_finish(true, out, true) end
        -- The widget now on top owns the screen: a panel contact under it
        -- taps nothing, and a Refresh would wash that widget.
        self.pen_panel = nil
        self:_drop_wash()
        self:_render_erased(out, true)
        self:_disarm(out)
    end
    return out
end

function Ctl:set_rotation(mode)
    local out = {}
    if mode == self.mode or (mode ~= 0 and mode ~= 1 and mode ~= 2
                             and mode ~= 3) then
        return out
    end
    self.mode = mode
    self.r = G.bb_rotation(mode)
    -- set_screen ends a drag and re-clamps; only a real change calls it.
    self.panel_drag = nil
    self.pn:set_screen(G.logical_size(self.r, self.W, self.H))
    -- The glue repaints the whole window in the new orientation.
    self:_painted()
    if self.opened and self.pn:is_open() then self:_panel_emit(out) end
    return out
end

--- An append or fsync failed.  cmd is the failed command as the glue got
-- it; for an append it lets the controller take that record back.  The
-- glue finishes the list first, skipping its later append, arm, ink and
-- publish_ink commands, then calls this: a render later in the same list
-- (an erase, an undo) would otherwise paint over the one this returns.
function Ctl:io_error(msg, cmd)
    local out = {}
    self:_fail(msg, out, nil, cmd)
    return out
end

--- kind: "stamp" | "publish" | "append" | "fsync"; us: its duration.
-- Summed into the next pen-up log line.  A non-finite value is dropped:
-- "%d" prints an infinity as -9223372036854775808.
function Ctl:note_timing(kind, us)
    if TIMING_SET[kind] and type(us) == "number" and us == us
       and us > -math.huge and us < math.huge then
        local tm = self.timing[kind]
        if not tm then
            tm = { n = 0, sum = 0, max = 0 }
            self.timing[kind] = tm
        end
        us = floor(us + 0.5)
        if us < 0 then us = 0 end
        tm.n, tm.sum = tm.n + 1, tm.sum + us
        if us > tm.max then tm.max = us end
    end
    return {}
end

--- The glue ran a publish command at now_rt_us, after the paint it
-- publishes.  A Refresh's wash waiting to run waits from here (the header's
-- Refresh rule); the command list that asked for the publish also asked
-- for the timer, and an early timer asks again for the rest.
function Ctl:published(now_rt_us)
    if self.wash_at then
        self.wash_at = (now_rt_us or self.now_rt_us()) + self.wash_us
    end
    return {}
end

function Ctl:pen_in_range() return self.in_range == true end
function Ctl:any_touch_down()
    return self.inp ~= nil and self.inp:any_touch_down()
end
function Ctl:is_open() return self.opened end

------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------

function Ctl:feed(ev)
    local out = {}
    if not self.opened then return out end
    if ev.type == 0 and ev.code == 3 and ev.src == "pen" then
        self.drops = self.drops + 1
    end
    local its = self.inp:feed(ev)
    if #its > 0 then self:_run(its, out) end
    return out
end

-- The one timer serves nb_input's long press, the pending leave and the
-- Refresh's wash.  An early call is harmless to all three: nb_input asks
-- again for the rest of its wait, and a leave or wash not yet due is asked
-- for again here.  The wash is checked before the leave: the two are never
-- pending together (a wash deadline exists only with no leave pending),
-- and a leave starts the wash's wait from a clock read after now_rt_us, so
-- a check after it would find more than the whole wait left and take that
-- for realtime stepping back.
function Ctl:on_timer(now_rt_us)
    local out = {}
    if not self.opened then return out end
    local wa = self.wash_at
    if wa then
        local left = wa - now_rt_us
        -- More than the whole wait left means realtime stepped back.
        if left <= 0 or left > self.wash_us then self:_wash(out) end
    end
    local la = self.leave_at
    if la then
        local left = la - now_rt_us
        -- More than the whole window left means realtime stepped back.
        if left <= 0 or left > self.leave_us then self:_leave(out, true) end
    end
    self:_run(self.inp:on_timer(now_rt_us), out)
    if self.leave_at or self.wash_at then
        local asked = false
        for i = 1, #out do
            if out[i].op == "schedule" then asked = true end
        end
        if not asked then self:_schedule(nil, out) end
    end
    return out
end

function Ctl:resync(snap, now_rt_us)
    local out = {}
    if not self.opened then return out end
    self:_run(self.inp:resync(snap, now_rt_us or self.now_rt_us()), out)
    return out
end

-- The intent dispatcher; also the host test's seam for intent orders
-- nb_input never produces (a swipe under a down pen).  Intents are only
-- read: nb_input's shared NONE must stay empty.  touch_down_changed is
-- not acted on: the glue switches touch ownership on the kernel's own
-- finger count, which a contact nb_input lost to SYN_DROPPED cannot hold.
function Ctl:_run(its, out)
    local i, n = 1, #its
    while i <= n do
        local it = its[i]
        local k = it.k
        if k == "stroke_point" then
            self:_point(it, out)
        elseif k == "stroke_begin" then
            self:_begin(it, out)
        elseif k == "stroke_end" then
            self:_end(it.gap, it.t, out)
        elseif k == "prox" then
            local nxt = its[i + 1]
            if not it.on and nxt and nxt.k == "prox" and nxt.on then
                -- A tool switch inside one report: the pen never left.
                i = i + 1
            elseif it.on then
                self:_prox_in(out)
            else
                self:_prox_out(out)
            end
        elseif k == "activity" then
            out[#out + 1] = { op = "activity" }
        elseif k == "timer" then
            self:_schedule(it.delay_us, out)
        elseif k == "pen_resync" then
            out[#out + 1] = { op = "resync_pen" }
        elseif k == "swipe" then
            local ldx, ldy = G.delta_to_logical(self.r, it.dx, it.dy)
            if abs(ldx) > abs(ldy) then self:_turn(ldx < 0 and 1 or -1, out) end
        elseif k == "multi_swipe" then
            local ldx, ldy = G.delta_to_logical(self.r, it.dx, it.dy)
            if abs(ldx) > abs(ldy) then
                self:_undo_redo(ldx < 0 and "u" or "r", out)
            end
        elseif k == "long_press" then
            self:_long_press(it, out)
        elseif k == "long_press_vetoed" then
            self:_long_press_vetoed(out)
        elseif k == "tap" then
            -- A tap on the canvas does nothing: the pen is the tool there.
            if it.target == "panel" then self:_panel_tap(it, out) end
        elseif k == "drag_begin" then
            self:_drag_begin(it)
        elseif k == "drag_move" then
            self:_drag_move(it, out)
        elseif k == "drag_end" then
            self:_drag_end(it, out)
        end
        i = i + 1
    end
end

function Ctl:_prox_in(out)
    self.in_range = true
    -- Back inside prox_leave_us: a dropout, not a leave.  The timer that
    -- was asked for finds nothing to do.
    self.leave_at = nil
    -- A Refresh waiting to wash now waits for this pen's leave.
    self.wash_at = nil
    self:_hold(true, out)
    self:_maybe_arm(out)
end

-- The pen went out of range; the leave waits prox_leave_us for it.
function Ctl:_prox_out(out)
    self.in_range = false
    if self.leave_us <= 0 then return self:_leave(out, true) end
    self.leave_at = self.now_rt_us() + self.leave_us
    self:_schedule(self.leave_us, out)
end

-- The pen has gone: sync what it wrote, run what waited for it, and let
-- rotation through.  visible=false (suspend) leaves a panel update
-- pending and repaints nothing.
function Ctl:_leave(out, visible)
    self.leave_at = nil
    self:_flush(out)
    self:_flush_prefs(out)
    self:_render_erased(out, visible)
    if visible and self.panel_stale then
        self.panel_stale = false
        if self.pn:is_open() then self:_panel_emit(out) end
    end
    self:_hold(false, out)
    self:_flush_debt(out, visible and not self.suspended and not self.wash_wanted)
    -- A Refresh the pen held waits from here, after what the leave painted.
    if self.wash_wanted then self:_wait_wash(out) end
end

-- deadline at (realtime us, or nil) as a delay from now, if it comes
-- sooner than delay (nil: no delay yet).
local function sooner(delay, at, now)
    if not at then return delay end
    local left = at - now
    if left < 0 then left = 0 end
    if delay == nil or left < delay then return left end
    return delay
end

-- The glue keeps one timer: ask for the sooner of delay_us (nil: none of
-- the caller's own) and the controller's deadlines, the pending leave and
-- the Refresh's wash.
function Ctl:_schedule(delay_us, out)
    local now = self.now_rt_us()
    delay_us = sooner(sooner(delay_us, self.leave_at, now), self.wash_at, now)
    if delay_us then out[#out + 1] = { op = "schedule", delay_us = delay_us } end
end

------------------------------------------------------------------------
-- Strokes
------------------------------------------------------------------------

-- What a pen-down does, from the end that touched and the settings:
-- "ink" (the brush), "erase" (area eraser, drawn white) or "strokes"
-- (the stroke eraser, not drawn).
function Ctl:_use(tool)
    if tool == "rubber" then
        return self:_pref("rubber") == "stroke" and "strokes" or "erase"
    end
    local mode = self:_pref("mode")
    if mode == "stroke_erase" then return "strokes" end
    if mode == "erase" then return "erase" end
    return "ink"
end

function Ctl:_begin(it, out)
    if self.stroke then self:_finish(true, out, true) end
    -- nb_input ends a contact at a proximity dropout (gap) and starts a
    -- new stroke where the nib comes back, 22-44 ms later: a stroke that
    -- begins inside the leave window of a gap is the rest of a contact.
    local cut_t, cut_panel = self.cut_t, self.cut_panel
    local cut = cut_t ~= nil and it.t - cut_t <= self.leave_us
    self.cut_t, self.cut_panel = nil, nil
    self.pen_panel = nil
    self.pen_down = true
    if not self.ink_live or self.suspended then return end
    -- Before the failure check: a panel tap works after a failed write,
    -- as a finger's does.
    -- Ownership follows the contact across a dropout, even if the nib
    -- returned outside the panel.  A cut tail cannot activate a button.
    if (cut and cut_panel) or self:_hit_test(it.x, it.y) == "panel" then
        self.pen_panel = { tool = it.tool, x = it.x, y = it.y, t0 = it.t,
                           d2 = 0, cut = cut }
        return
    end
    if self.failed then return end
    if self.page.next_action > MAX_ACTION then
        if not self.full_warned then
            self.full_warned = true
            out[#out + 1] = { op = "toast", text = format(
                "Notebook: page %s holds too many actions; it takes no"
                .. " more ink.", int(self.page_n)) }
        end
        return
    end
    local tool = it.tool
    local use = self:_use(tool)
    local s = { tool = tool, use = use, page = self.page_n, rot = self.mode,
                pts = { it }, n = 1, run = 0, max_run = 0, max_lag = 0,
                brush = use == "strokes" and "stroke_eraser" or self:_pref("brush"),
                size = use == "strokes" and "-" or self:_pref("size"), spans = 0 }
    self.stroke = s
    self:_clock(s, it.t)
    if use == "strokes" then
        s.R, s.hit, s.hits, s.seg = self.sx_r, {}, 0, {}
        self:_sx_test(s, it, nil, out)
        return
    end
    local brush, size, cfg = self:_pref("brush"), self:_pref("size"), self.cfg
    local style
    if use == "ink" then
        style = Brush.style(brush, size, "pen", cfg)
    else
        style = Brush.style(brush, size, "eraser", cfg)
        if tool == "pen" then
            style.plo, style.phi = cfg.pen_p_lo, cfg.pen_p_hi
        end
    end
    s.style = style
    if self:_stamp(style, it, nil, out) then
        out[#out + 1] = { op = "publish_ink" }
    end
end

function Ctl:_point(it, out)
    local pp = self.pen_panel
    if pp then
        local dx, dy = it.x - pp.x, it.y - pp.y
        local d2 = dx * dx + dy * dy
        if d2 > pp.d2 then pp.d2 = d2 end
        return
    end
    local s = self.stroke
    if not s then return end
    local prev = s.pts[s.n]
    s.n = s.n + 1
    s.pts[s.n] = it
    self:_clock(s, it.t)
    if s.use == "strokes" then
        self:_sx_test(s, prev, it, out)
    elseif self:_stamp(s.style, prev, it, out) then
        out[#out + 1] = { op = "publish_ink" }
    end
end

function Ctl:_end(gap, t, out)
    self.pen_down = false
    if self.stroke then self:_finish(gap, out, true) end
    local pl = self.pending_load
    if pl then
        self.pending_load = nil
        self:_show_page(pl.n, pl.page, out)
    end
    -- After the page a load left waiting, so a tap on Prev or Next turns
    -- from the page on screen.
    local pp = self.pen_panel
    if pp then
        self.pen_panel = nil
        local slop, dur = self.cfg.tap_slop_px, t - pp.t0
        -- Realtime can step back mid-tap; nb_input's finger taps clamp too.
        if dur < 0 then dur = 0 end
        if pp.tool == "pen" and not gap and not pp.cut
           and dur <= self.cfg.tap_max_us and pp.d2 <= slop * slop then
            self:_panel_tap(pp, out)
        end
    end
    self.cut_t = gap and t or nil
    self.cut_panel = gap and pp ~= nil or nil
end

-- Loop health for the pen-up log.  A sample stamped no later than the
-- moment the previous one was handled was already queued then, so it
-- came in the same read batch: batch is the longest such run, lag the
-- largest handling delay.  Both clocks are CLOCK_REALTIME.
function Ctl:_clock(s, t)
    local now = self.now_rt_us()
    local last = s.last_now
    if last and t <= last then s.run = s.run + 1 else s.run = 1 end
    if s.run > s.max_run then s.max_run = s.run end
    local lag = now - t
    if lag > s.max_lag then s.max_lag = lag end
    s.last_now = now
end

-- One ink command for a dot (b nil) or the segment a -> b, arming first
-- if the plane is not ours.  Returns whether anything was drawn.
function Ctl:_stamp(style, a, b, out)
    col_spans, col_n, col_dens = {}, 0, nil
    if b then
        Brush.segment_spans(style, a, b, self.W, self.H, collect)
    else
        Brush.dot_spans(style, a, self.W, self.H, collect)
    end
    local spans, dens = col_spans, col_dens
    col_spans = nil
    if col_n == 0 then return false end
    self.stroke.spans = self.stroke.spans + col_n / 3
    if not self.armed then self:_arm(out) end
    out[#out + 1] = { op = "ink", spans = spans, comp = style.comp,
                      pat = style.pat, dens = dens }
    return true
end

-- A picked stroke vanishes at once: its own geometry, painted white.
function Ctl:_whiteout(entry, out)
    col_spans, col_n = {}, 0
    Brush.render(entry.style, entry.points, self.W, self.H, collect)
    local spans = col_spans
    col_spans = nil
    if col_n == 0 then return false end
    self.stroke.spans = self.stroke.spans + col_n / 3
    if not self.armed then self:_arm(out) end
    out[#out + 1] = { op = "ink", spans = spans, comp = "white", pat = "solid" }
    return true
end

-- The stroke eraser's newest leg against every visible ink stroke not
-- yet picked.  Legs are tested one report at a time, prev -> cur, which
-- is the whole path's test split along its joins.
function Ctl:_sx_test(s, a, b, out)
    local seg = s.seg
    seg[1], seg[2] = a, b
    local drew = false
    local strokes = self.page.strokes
    -- Brush.hits' own first test, hoisted out of the loop: the leg's box
    -- grown by the reach against each recorded box (bb bounds pixel
    -- centres; the hull reaches 1 px past).  A crowded page is mostly
    -- rejected here, at four comparisons a stroke.
    local R, bx, by = s.R, (b or a).x, (b or a).y
    local lx0 = (a.x < bx and a.x or bx) - R - 1
    local lx1 = (a.x > bx and a.x or bx) + R + 1
    local ly0 = (a.y < by and a.y or by) - R - 1
    local ly1 = (a.y > by and a.y or by) + R + 1
    for i = 1, #strokes do
        local e = strokes[i]
        local bb = e.bb
        if bb[1] <= lx1 and bb[3] >= lx0 and bb[2] <= ly1 and bb[4] >= ly0
           and not s.hit[e] and e.style.tool ~= "eraser"
           and Brush.hits(seg, R, e.points, e.style, bb) then
            s.hit[e] = true
            s.hits = s.hits + 1
            if self:_whiteout(e, out) then drew = true end
        end
    end
    if drew then out[#out + 1] = { op = "publish_ink" } end
end

-- The union of stroke boxes, clipped to the panel, as a repaint region.
local function grow(box, bb)
    if not box then return { bb[1], bb[2], bb[3], bb[4] } end
    if bb[1] < box[1] then box[1] = bb[1] end
    if bb[2] < box[2] then box[2] = bb[2] end
    if bb[3] > box[3] then box[3] = bb[3] end
    if bb[4] > box[4] then box[4] = bb[4] end
    return box
end

function Ctl:_region(box)
    if not box then return nil end
    local x0, y0 = box[1] < 0 and 0 or box[1], box[2] < 0 and 0 or box[2]
    local x1 = box[3] > self.W - 1 and self.W - 1 or box[3]
    local y1 = box[4] > self.H - 1 and self.H - 1 or box[4]
    if x1 < x0 or y1 < y0 then return nil end
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- Record the stroke.  repaint=false (suspend, close) still rebuilds the
-- page buffer after a stroke erase, since the next paint blits it.
function Ctl:_finish(gap, out, repaint)
    local s = self.stroke
    self.stroke = nil
    local page = self.page
    local rec, box
    if s.use == "strokes" then
        if s.hits > 0 then
            -- page.strokes is in file order, so the ids come out ascending.
            local ids = {}
            for _, e in ipairs(page.strokes) do
                if s.hit[e] then
                    ids[#ids + 1] = e.a
                    box = grow(box, e.bb)
                end
            end
            rec = { k = "x", a = page.next_action, ids = ids }
        end
    else
        local x0, y0, x1, y1 = Brush.bbox(s.style, s.pts)
        box = { x0, y0, x1, y1 }
        rec = J.stroke_record(page.next_action, s.style, s.rot, s.pts[1].t,
                              s.pts, gap, box)
    end
    if rec then
        local ok, line = pcall(J.encode, rec)
        if ok then
            self:_append(out, s.page, page, rec, line, box)
        else
            self:_fail(line, out, s)
            rec = nil
        end
    end
    if rec and rec.k == "x" then
        -- The picked strokes are already white on the glass; rebuilding
        -- what they overlapped waits for the leave while the pen is in
        -- range (the header's stroke-eraser rule).
        self.erased_box = grow(self.erased_box, box)
        if not (repaint and self.in_range) then
            self:_render_erased(out, repaint)
        end
    end
    -- The panel does not wait: the hovering pen can tap it (the header's
    -- panel rule).
    self:_panel_sync(out, repaint)
    self:_log(s, gap, rec, out)
    -- An area erase leaves a ghost of the ink it whitened, and a stroke
    -- erase of the strokes it removed; the unit waits for the leave, since
    -- the pen is still in range here (the ghost debt rule).
    if s.use == "erase" or (s.use == "strokes" and s.hits > 0) then
        self:_charge(1, out)
    end
end

-- The page render a stroke erase put off, over the page as it now is:
-- the stroke's page, because nothing turns the page under a down pen and
-- a turn renders the whole page and drops the box.
function Ctl:_render_erased(out, repaint)
    local region = self:_region(self.erased_box)
    self.erased_box = nil
    if not region then return end
    self:_disarm(out)
    out[#out + 1] = { op = "render_page", page = self.page_n,
                      strokes = snapshot(self.page.strokes), region = region }
    if repaint then
        out[#out + 1] = { op = "repaint", region = region }
        self:_painted()
    end
end

function Ctl:_log(s, gap, rec, out)
    -- Realtime can step back mid-stroke; the journal clamps its deltas,
    -- and so does the log.
    local dur = s.pts[s.n].t - s.pts[1].t
    if dur < 0 then dur = 0 end
    local parts = {
        "pen-up",
        "page=" .. int(s.page),
        "rec=" .. (rec and (rec.k .. int(rec.a)) or "-"),
        "tool=" .. s.tool,
        "use=" .. s.use,
        "brush=" .. s.brush,
        "size=" .. s.size,
        "spans=" .. int(s.spans),
        "n=" .. int(s.n),
        "dur=" .. int(dur) .. "us",
        "gap=" .. (gap and "1" or "0"),
        "hits=" .. int(s.hits or 0),
        "batch=" .. int(s.max_run),
        "lag=" .. int(s.max_lag) .. "us",
        "drops=" .. int(self.drops),
    }
    local timing = self.timing
    for _, kind in ipairs(TIMING_KINDS) do
        local tm = timing[kind]
        parts[#parts + 1] = kind .. "="
            .. (tm and format("%d/%d/%dus", tm.n, tm.sum, tm.max) or "-")
    end
    self.timing, self.drops = {}, 0
    out[#out + 1] = { op = "log", line = concat(parts, " ") }
end

------------------------------------------------------------------------
-- Pages, undo and redo
------------------------------------------------------------------------

function Ctl:_turn(delta, out)
    if self.pen_down then return end
    local target = (self.loading or self.page_n) + delta
    if abs(target) > MAX_PAGE then return end
    self.loading = target
    -- The last append's io_error came at the end of its own list, before
    -- this one; kept, it would hold the page being left, every stroke
    -- and point of it, until the next append.
    self.last_append = nil
    self:_disarm(out)
    out[#out + 1] = { op = "load_page", page = target }
end

--- The glue's answer to load_page.  page nil means the read failed; err
-- says why, and the page on screen stays.  A load overtaken by a later
-- turn is dropped.
function Ctl:page_loaded(n, page, err)
    local out = {}
    if not self.opened or n ~= self.loading then return out end
    if not page then
        self.loading = nil
        out[#out + 1] = { op = "toast", text = format(
            "Notebook: cannot read page %s (%s).", int(n), tostring(err)) }
        return out
    end
    if self.pen_down then
        self.pending_load = { n = n, page = page }
        return out
    end
    self:_show_page(n, page, out)
    return out
end

function Ctl:_show_page(n, page, out)
    self.loading = nil
    self.page_n, self.page = n, page
    self.full_warned = false
    -- A wash must not ride a page turn (the header's Refresh rule).
    self:_drop_wash()
    -- The whole page is rendered below, so a stroke erase's render still
    -- waiting (for the page left) has nothing left to do.
    self.erased_box = nil
    self:_disarm(out)
    out[#out + 1] = { op = "render_page", page = n,
                      strokes = snapshot(page.strokes) }
    self:_panel_sync(out, true)
    out[#out + 1] = { op = "repaint" }
    if self.in_range or self.pen_down or self.leave_at then
        self.turn_debt = self.turn_debt + 1
    else
        out[#out + 1] = { op = "washer_charge" }
    end
end

function Ctl:_undo_redo(kind, out)
    if self.pen_down or self.loading then return end
    if self.failed then
        out[#out + 1] = { op = "toast", text =
                          "Notebook: saving failed; undo and redo are off." }
        return
    end
    local page = self.page
    local target
    if kind == "u" then
        target = page.undo_target
    else
        target = page.redo_target
    end
    if not target then return end
    local rec = { k = kind, a = target }
    local ok, line = pcall(J.encode, rec)
    if not ok then
        self:_fail(line, out)
        return
    end
    local before = page.strokes
    local kept = self:_append(out, self.page_n, page, rec, line, nil)
    -- The strokes that appeared or vanished bound what can change.
    local seen, box = {}, nil
    for _, e in ipairs(before) do seen[e] = true end
    for _, e in ipairs(page.strokes) do
        if seen[e] then seen[e] = false else box = grow(box, e.bb) end
    end
    for _, e in ipairs(before) do
        if seen[e] then box = grow(box, e.bb) end
    end
    kept.box = box
    -- A nil region would mean the whole page; nothing visible changed, so
    -- nothing is rendered.
    local region = self:_region(box)
    if region then
        self:_disarm(out)
        out[#out + 1] = { op = "render_page", page = self.page_n,
                          strokes = snapshot(page.strokes), region = region }
    end
    self:_panel_sync(out, true)
    if region then
        out[#out + 1] = { op = "repaint", region = region }
        self:_painted()
    end
    -- Touch drove this, so the pen is out of range and the sync can run
    -- now; the check keeps the fsync rule true whatever the caller.
    if not self.in_range then self:_flush(out) end
    -- What the render took away or brought back leaves a ghost; a pen's
    -- tap on Undo or Redo charges at its leave (the ghost debt rule).
    if region then self:_charge(1, out) end
end

-- Emit a record's append and apply it to the page in memory now: the
-- glue writes after this call returns, and the next report must see the
-- page as written.  What the write changes on screen (box, the union of
-- the strokes it adds or removes) and the page before it are kept, so
-- io_error can take the record back if this write is the one that
-- failed.  J.apply appends a new stroke to page.strokes in place and
-- replaces the table for any other record, so the old table and its
-- length are enough to restore either.  Returns the kept state.
function Ctl:_append(out, n, page, rec, line, box)
    local cmd = { op = "append", page = n, line = line }
    out[#out + 1] = cmd
    local strokes = page.strokes
    local kept = { cmd = cmd, page = page, strokes = strokes, n = #strokes,
                   box = box }
    self.last_append = kept
    J.apply(page, rec)
    self.dirty[n] = true
    self.last_written = n
    return kept
end

-- Every page appended to since its last fsync, in page order.
function Ctl:_flush(out)
    local pages = {}
    for n in pairs(self.dirty) do pages[#pages + 1] = n end
    if #pages == 0 then return end
    sort(pages)
    for _, n in ipairs(pages) do
        out[#out + 1] = { op = "fsync", page = n }
    end
    self.dirty = {}
end

------------------------------------------------------------------------
-- The panel
------------------------------------------------------------------------

function Ctl:_hit_test(px, py)
    local pn = self.pn
    if pn:is_open() then
        local lx, ly = G.to_logical(self.r, self.W, self.H, px, py)
        if pn:hit(lx, ly) then return "panel" end
    end
    return "canvas"
end

function Ctl:_panel_state()
    local page = self.page
    return {
        brush = self:_pref("brush"), size = self:_pref("size"),
        mode = self:_pref("mode"), rubber = self:_pref("rubber"),
        page = self.page_n,
        can_undo = not self.failed and page.undo_target ~= nil,
        can_redo = not self.failed and page.redo_target ~= nil,
        nb_title = self.nb.title,
    }
end

local STATE_KEYS = { "brush", "size", "mode", "rubber", "page", "can_undo",
                     "can_redo", "nb_title" }

local function same_state(a, b)
    for _, k in ipairs(STATE_KEYS) do
        if a[k] ~= b[k] then return false end
    end
    return true
end

-- Show, move or hide the panel as it now is.
function Ctl:_panel_emit(out)
    local st = self:_panel_state()
    self.panel_state = st
    self.L = self.pn:layout(st)
    self.panel_stale = false
    self:_disarm(out)
    out[#out + 1] = { op = "panel", layout = self.L }
    self:_painted()
end

-- The panel closes, and the glue paints the page back where it was, which
-- leaves a ghost of the panel's buttons: charged, unless the close is the
-- Refresh's, which washes (the ghost debt rule).
function Ctl:_close_panel(out, charge)
    self.panel_drag = nil
    self.pn:close()
    self:_panel_emit(out)
    if charge then self:_charge(1, out) end
end

-- Lay out again when what the panel shows changed.  now=false defers
-- the visible update while the pen is in range.
function Ctl:_panel_sync(out, now)
    local st = self:_panel_state()
    local last = self.panel_state
    if last and same_state(st, last) then return end
    if not self.pn:is_open() then
        self.panel_state = st
        self.L = self.pn:layout(st)
        return
    end
    if self.in_range and not now then
        self.panel_state = st
        self.L = self.pn:layout(st)
        self.panel_stale = true
        return
    end
    self:_panel_emit(out)
end

function Ctl:_long_press(it, out)
    if self.pen_down then return end
    local r, W, H = self.r, self.W, self.H
    local lx, ly = G.to_logical(r, W, H, it.x, it.y)
    local lw, lh = G.logical_size(r, W, H)
    self.panel_drag = nil
    self.pn:open(lx, ly, lw, lh)
    self:_panel_emit(out)
end

-- The pen arrived while the contact that long-pressed was still down: a
-- palm that rested before the pen came into range.  No panel interaction
-- can have come between (another contact would have joined the same
-- session), so the panel open now is the one it opened, or one it moved.
-- Closing at once, with the pen in range, costs one panel repaint, which
-- the refresh guard keeps out of the DU rectangle.
function Ctl:_long_press_vetoed(out)
    if not self.pn:is_open() then return end
    self:_close_panel(out, true)
end

local ACTIONS = {
    ["undo"] = function(self, out) self:_undo_redo("u", out) end,
    ["redo"] = function(self, out) self:_undo_redo("r", out) end,
    ["page:prev"] = function(self, out) self:_turn(-1, out) end,
    ["page:next"] = function(self, out) self:_turn(1, out) end,
    ["nb:new"] = function(_, out) out[#out + 1] = { op = "new_notebook" } end,
    ["nb:open"] = function(_, out) out[#out + 1] = { op = "open_list" } end,
    ["nb:close"] = function(_, out)
        out[#out + 1] = { op = "close_notebook" }
    end,
    ["refresh"] = function(self, out) self:_refresh(out) end,
}

function Ctl:_panel_tap(it, out)
    local pn = self.pn
    if self.pen_down or not pn:is_open() then return end
    local id = pn:hit(G.to_logical(self.r, self.W, self.H, it.x, it.y))
    if not id then return end
    if id == "close" then return self:_close_panel(out, true) end
    local action = ACTIONS[id]
    if action then return action(self, out) end
    local key, value = id:match("^(%a+):(.+)$")
    -- A tap on the checked button chooses nothing; any other tap is the
    -- user's choice, and is kept even when it is today's default.
    if key and VALID[key] and VALID[key][value]
       and self:_pref(key) ~= value then
        self.prefs[key] = value
        -- The panel first: the prefs write fsyncs, and the tap should show.
        self:_panel_sync(out, true)
        self:_save_prefs(out)
    end
end

-- Only a drag from the title bar moves the panel; a flick from anywhere
-- on it closes it (Panel:drag_end decides on speed alone).
function Ctl:_drag_begin(it)
    local pn = self.pn
    if not pn:is_open() then return end
    local lx, ly = G.to_logical(self.r, self.W, self.H, it.x, it.y)
    local moving = pn:hit(lx, ly) == "title"
    if moving then pn:drag_begin(lx, ly) end
    self.panel_drag = { moving = moving }
end

function Ctl:_drag_move(it, out)
    local d = self.panel_drag
    if not (d and d.moving) then return end
    if self.pn:drag_move(G.to_logical(self.r, self.W, self.H, it.x, it.y)) then
        self:_panel_emit(out)
    end
end

-- panel_drag exists only for a drag that began on the open panel, and
-- whatever closes the panel meanwhile clears it, so a flick here closes an
-- open panel, and is charged as Close is.
function Ctl:_drag_end(it, out)
    local d = self.panel_drag
    self.panel_drag = nil
    if not d then return end
    local lvx, lvy = G.delta_to_logical(self.r, it.vx, it.vy)
    if self.pn:drag_end(lvx, lvy) == "flicked" then
        self:_panel_emit(out)
        self:_charge(1, out)
    end
end

------------------------------------------------------------------------
-- The Refresh button and the washer's ghost debt
------------------------------------------------------------------------

-- The panel closes, the glue paints the page where it was and publishes
-- that paint, and the wash waits (the header's Refresh rule).
function Ctl:_refresh(out)
    self:_close_panel(out, false)
    out[#out + 1] = { op = "publish" }
    self.wash_wanted = true
    self:_wait_wash(out)
end

-- Start the wash's wait from now, unless the pen is here: then its leave
-- starts it.
function Ctl:_wait_wash(out)
    if self.in_range or self.pen_down or self.leave_at then
        self.wash_at = nil
        return
    end
    self.wash_at = self.now_rt_us() + self.wash_us
    self:_schedule(self.wash_us, out)
end

-- Something was painted while the wash waits: the wait starts again from
-- this paint.  The timer asked for the old deadline fires early, and
-- on_timer asks for the new one.
function Ctl:_painted()
    if self.wash_at then self.wash_at = self.now_rt_us() + self.wash_us end
end

function Ctl:_drop_wash()
    self.wash_wanted, self.wash_at = false, nil
end

-- The wait is over.  wash_at is only ever set with the pen out of range
-- and no leave pending (_wait_wash; _prox_in clears it), so the pen cannot
-- be here; it is checked anyway, because a wash under the pen is the one
-- thing this must never do, and the leave would start the wait again.
function Ctl:_wash(out)
    self.wash_at = nil
    if self.in_range or self.pen_down or self.leave_at then return end
    self.wash_wanted = false
    self:_disarm(out)
    out[#out + 1] = { op = "wash" }
end

-- n units of ghost debt.  They go to the washer now when the pen is away
-- (a finger's action, at the touch's end), else at the pen's leave.
function Ctl:_charge(n, out)
    self.ghost_debt = self.ghost_debt + n
    if not (self.in_range or self.pen_down or self.leave_at) then
        self:_flush_debt(out)
    end
end

-- The units owed, as one command: the leave, suspend and close.
function Ctl:_flush_debt(out, allow_turn_wash)
    local turns = self.turn_debt
    self.turn_debt = 0
    if turns > 0 and not allow_turn_wash then
        -- Close and suspend retain the charge but never start a
        -- bundled wash during teardown or over the screensaver.
        self.ghost_debt = self.ghost_debt + turns
    end
    local n = self.ghost_debt
    if n > 0 then
        self.ghost_debt = 0
        out[#out + 1] = { op = "washer_debt", n = n }
    end
    -- A bundled wash also cleans the ghost-producing actions from this
    -- visit, so those charges must reach the washer before this one.
    if turns > 0 and allow_turn_wash then
        out[#out + 1] = { op = "washer_charge", n = turns }
    end
end

------------------------------------------------------------------------
-- Hints, hold, prefs, failure
------------------------------------------------------------------------

function Ctl:_arm(out)
    local W, H = self.W, self.H
    local rects = { { x = 0, y = 0, w = W, h = H, hint = HINT_DU } }
    local L = self.pn:is_open() and self.L
    if L then
        local px, py, pw, ph = G.rect_to_physical(self.r, W, H,
                                                  L.x, L.y, L.w, L.h)
        if pw > 0 and ph > 0 then
            rects[2] = { x = px, y = py, w = pw, h = ph, hint = HINT_PANEL }
        end
    end
    self.armed = true
    self._disarmed_out = nil
    out[#out + 1] = { op = "arm", rects = rects }
end

function Ctl:_maybe_arm(out)
    if self.in_range and self.ink_live and not self.armed and not self.failed
       and not self.suspended then
        self:_arm(out)
    end
end

-- Once per command list unless an arm came between: the glue's hint
-- owner makes a second disarm a no-op anyway, and one reads cleaner.
function Ctl:_disarm(out)
    if not self.armed and self._disarmed_out == out then return end
    self.armed = false
    self._disarmed_out = out
    out[#out + 1] = { op = "disarm" }
end

function Ctl:_hold(on, out)
    if self.held == on then return end
    self.held = on
    out[#out + 1] = { op = "rotation_hold", on = on }
end

-- save_prefs is a write_atomic, which fsyncs.  A finger tap has the pen
-- out of range by construction; a pen tap does not, so its choice is
-- written when the pen leaves, at suspend or at close, as a page's fsync
-- is (the header's fsync rule).
function Ctl:_save_prefs(out)
    if self.in_range then
        self.prefs_dirty = true
        return
    end
    self:_emit_prefs(out)
end

-- Every save_prefs writes all of the prefs, so any of them takes a choice
-- that was waiting with it.
function Ctl:_emit_prefs(out)
    self.prefs_dirty = false
    out[#out + 1] = { op = "save_prefs", prefs = self:_prefs_copy() }
end

-- A choice a pen tap made, where an fsync is allowed: the leave, suspend
-- and close.
function Ctl:_flush_prefs(out)
    if self.prefs_dirty then self:_emit_prefs(out) end
end

-- The settings the user chose (absent ones stay absent) and the reopen
-- place, which is state rather than a setting.
function Ctl:_prefs_copy()
    local p = self.prefs
    local lp
    if p.last_page then
        lp = {}
        for id, n in pairs(p.last_page) do lp[id] = n end
    end
    return { brush = p.brush, size = p.size, mode = p.mode, rubber = p.rubber,
             last_id = p.last_id, last_page = lp }
end

-- Reopening a notebook goes to the page last written on in it (main.lua's
-- prepare reads last_page), saved at suspend and close, the two ways a
-- session usually ends.
function Ctl:_save_place(out)
    local id, n = self.nb.id, self.last_written
    if not (n and J.is_id(id)) then return end
    local p = self.prefs
    p.last_page = p.last_page or {}
    if p.last_page[id] == n and p.last_id == id then return end
    p.last_page[id] = n
    p.last_id = id
    self:_emit_prefs(out)
end

-- The pixels a stroke has drawn so far: its own box, or for the stroke
-- eraser the boxes of the strokes it whited out.
function Ctl:_drawn_box(s)
    local box
    if s.use == "strokes" then
        for _, e in ipairs(self.page.strokes) do
            if s.hit[e] then box = grow(box, e.bb) end
        end
    else
        local x0, y0, x1, y1 = Brush.bbox(s.style, s.pts)
        box = { x0, y0, x1, y1 }
    end
    return box
end

-- dropped: a stroke that will now never be recorded.  cmd: the command
-- whose execution failed, if the glue passed it.  When it is the last
-- append, that record is taken back out of the page in memory: nothing
-- is applied after a failure, so page.strokes is all that is read again.
-- What the failed record and the dropped stroke drew is rebuilt from the
-- page, so the screen shows no ink the journal lacks.
function Ctl:_fail(msg, out, dropped, cmd)
    msg = tostring(msg)
    out[#out + 1] = { op = "log", line = "io-error " .. msg }
    if self.failed then return end
    self.failed = true
    dropped = dropped or self.stroke
    self.stroke = nil
    self:_disarm(out)
    out[#out + 1] = { op = "toast", text =
                      "Notebook: cannot save (" .. msg .. "). Ink is off." }
    local box
    local la = self.last_append
    self.last_append = nil
    if la and cmd ~= nil and cmd == la.cmd then
        local old = la.strokes
        for i = #old, la.n + 1, -1 do old[i] = nil end
        la.page.strokes = old
        if la.page == self.page and la.box then box = grow(nil, la.box) end
    end
    if not self.opened then return end
    if dropped then
        local db = self:_drawn_box(dropped)
        if db then box = grow(box, db) end
    end
    local region = self:_region(box)
    if region then
        out[#out + 1] = { op = "render_page", page = self.page_n,
                          strokes = snapshot(self.page.strokes),
                          region = region }
        out[#out + 1] = { op = "repaint", region = region }
        self:_painted()
    end
    self:_panel_sync(out, true)
end

return Ctl
