--[[--
nb_panel -- the notebook's floating panel, as a pure model.

No widgets and no Blitbuffer: the panel's geometry, its checked and
enabled states, hit testing, dragging and flick-to-close are plain
arithmetic in LOGICAL px (KOReader's rotated space, so the text the glue
paints is upright), tested on any luajit by test-notebook-panel.lua.
The glue paints layout() with KOReader widgets; the controller feeds
touch in and maps the returned item ids to actions.

Why the notebook hit-tests its own panel: while it is open the notebook
consumes touch in the input adjust hook, so KOReader never builds the
Gesture events its Button widgets listen for.

Shape: a title bar (the notebook title and page number, and a Close
button), then one group of buttons per setting, each group starting a new
row and wrapping within the panel's width.  The size depends only on the
screen width and nb_config, never on the state, so the panel does not jump
when the page number grows a digit.  On the PineNote nothing wraps and the
panel is 984 x 576 in either orientation; on a screen too short for a
wrapped panel (far smaller than the PineNote's) it pins to the top margin,
title bar first, and its last rows fall off the bottom.

The panel's pure model cannot measure text, so it sizes buttons from an
estimate: labels are short ASCII, and LABEL_CHAR_PX allows about 0.6 em
per character at LABEL_FONT_PX, which covers mixed-case sans text.  The
layout reports that font size (L.font_px) so the glue renders at the size
the estimate assumed; the glue should still bound each label to its
button's width, since a wider real font could overrun it.
--]]

local Panel = {}
Panel.__index = Panel

Panel.LABEL_FONT_PX = 32
Panel.LABEL_CHAR_PX = 20

local floor = math.floor

-- Groups in display order.  `radio` names the state field whose value
-- marks one button checked.  The brush ids must match nb_brush's
-- Brush.IDS; they are listed here rather than required so the panel stays
-- loadable (and testable) on its own.
local GROUPS = {
    { radio = "brush",
      { "fine", "Fine" }, { "ballpoint", "Ball" }, { "brushpen", "Brush" },
      { "marker", "Marker" }, { "pencil", "Pencil" },
      { "highlighter", "Hilite" } },
    { radio = "size",
      { "S", "S" }, { "M", "M" }, { "L", "L" } },
    { radio = "mode",
      { "write", "Write" }, { "erase", "Erase" },
      { "stroke_erase", "Erase strokes" } },
    { radio = "rubber",
      { "area", "Rubber: area" }, { "stroke", "Rubber: strokes" } },
    { { "undo", "Undo" }, { "redo", "Redo" },
      { "page:prev", "< Prev" }, { "page:next", "Next >" } },
    { { "nb:new", "New" }, { "nb:open", "Open" }, { "nb:close", "Exit" } },
}

local CLOSE_LABEL = "Close"

local function round(v)
    return floor(v + 0.5)
end

function Panel.new(cfg)
    local self = setmetatable({}, Panel)
    self.min_px = cfg.panel_button_min_px
    -- One spacing tunable serves three roles: the screen margin, the
    -- panel's inner padding, and the space between groups; buttons within
    -- a group sit half as far apart.
    self.pad = cfg.panel_margin_px
    self.gap = floor(cfg.panel_margin_px / 2)
    self.max_w = cfg.panel_max_w_px
    self.flick_min = cfg.flick_min_px_per_s
    -- How much of the title bar a drag must leave on screen: enough to
    -- put a finger on and drag it back.
    self.grab_px = 2 * cfg.panel_button_min_px
    self.opened = false
    self.dragging = false
    self.state = {}
    self.x, self.y = 0, 0
    self.lw, self.lh = cfg.W, cfg.H
    self:_measure()
    return self
end

local function label_w(self, label)
    local w = #label * Panel.LABEL_CHAR_PX + 2 * self.pad
    if w < self.min_px then w = self.min_px end
    return w
end

-- Lay out the panel for the current screen width, relative to the
-- panel's own origin.  Buttons in a group share one width, the widest
-- label's, so each group reads as a grid.
function Panel:_measure()
    local pad, gap, min_px = self.pad, self.gap, self.min_px
    local close_w = label_w(self, CLOSE_LABEL)

    local cap = self.max_w
    if self.lw - 2 * pad < cap then cap = self.lw - 2 * pad end
    local inner_max = cap - 2 * pad
    -- Never so narrow that the title loses its grab area beside Close;
    -- the button minimum wins over the width cap.
    local inner_min = close_w + gap + min_px
    if inner_max < inner_min then inner_max = inner_min end

    local groups, natural = {}, 0
    for gi, g in ipairs(GROUPS) do
        local bw = 0
        for _, b in ipairs(g) do
            local w = label_w(self, b[2])
            if w > bw then bw = w end
        end
        if bw > inner_max then bw = inner_max end
        groups[gi] = bw
        local row = #g * bw + (#g - 1) * gap
        if row > natural then natural = row end
    end
    local inner = natural
    if inner > inner_max then inner = inner_max end
    if inner < inner_min then inner = inner_min end

    local rel = {}
    local close_x = pad + inner - close_w
    -- rel[1] is the title.  The title bar is the whole strip above the
    -- first group; hit() calls all of it outside Close "title".  Its width
    -- for the drag clamp stops at Close, which is no place to grab.
    rel[1] = { id = "title", kind = "title",
               x = pad, y = pad, w = close_x - gap - pad, h = min_px }
    rel[2] = { id = "close", kind = "button", label = CLOSE_LABEL,
               x = close_x, y = pad, w = close_w, h = min_px }
    local y = pad + min_px
    self.title_bar_h = y
    self.title_bar_w = close_x

    for gi, g in ipairs(GROUPS) do
        local bw = groups[gi]
        local per_row = floor((inner + gap) / (bw + gap))
        if per_row < 1 then per_row = 1 end
        y = y + pad
        local rows = 0
        for i, b in ipairs(g) do
            local row, col = floor((i - 1) / per_row), (i - 1) % per_row
            local id = g.radio and (g.radio .. ":" .. b[1]) or b[1]
            rel[#rel + 1] = {
                id = id, kind = "button", label = b[2],
                radio = g.radio, value = b[1],
                x = pad + col * (bw + gap), y = y + row * (min_px + gap),
                w = bw, h = min_px,
            }
            rows = row + 1
        end
        y = y + rows * min_px + (rows - 1) * gap
    end

    self.rel = rel
    self.w = inner + 2 * pad
    self.h = y + pad
end

local function clamp(v, lo, hi)
    -- A panel larger than the range pins to its low end (top-left).
    if v > hi then v = hi end
    if v < lo then v = lo end
    return v
end

-- Fully on screen, inside the margin: where open and a rotation put it.
function Panel:_clamp_full()
    local pad = self.pad
    self.x = clamp(self.x, pad, self.lw - pad - self.w)
    self.y = clamp(self.y, pad, self.lh - pad - self.h)
end

-- After a drag the panel may hang off the sides and the bottom, but its
-- whole title bar height and at least grab_px of the title bar's width
-- stay on screen, so it can always be dragged back or flicked away.
function Panel:_clamp_title()
    local keep = self.grab_px
    if keep > self.title_bar_w then keep = self.title_bar_w end
    self.x = clamp(self.x, keep - self.title_bar_w, self.lw - keep)
    self.y = clamp(self.y, 0, self.lh - self.title_bar_h)
end

-- lx, ly: the long press, which the panel centres on; lw, lh: the
-- logical screen.
function Panel:open(lx, ly, lw, lh)
    self.lw, self.lh = lw, lh
    self:_measure()
    self.x = floor(lx - self.w / 2)
    self.y = floor(ly - self.h / 2)
    self:_clamp_full()
    self.opened = true
    self.dragging = false
end

function Panel:close()
    self.opened = false
    self.dragging = false
end

function Panel:is_open()
    return self.opened
end

local function is_enabled(item, st)
    if item.id == "undo" then return st.can_undo == true end
    if item.id == "redo" then return st.can_redo == true end
    return true
end

local function is_checked(item, st)
    return item.radio ~= nil and st[item.radio] == item.value
end

-- state = {brush, size, mode, rubber, page, can_undo, can_redo, nb_title}.
-- Returns nil while closed, so {op="panel", layout=pn:layout(st)} hides
-- it.  Every call builds fresh tables: the glue may still hold the last L.
function Panel:layout(state)
    self.state = state or {}
    if not self.opened then return nil end
    local st = self.state
    local page = st.page and string.format("%d", st.page) or "?"
    local title = (st.nb_title or "Notebook") .. " - page " .. page
    local items = {}
    for i, r in ipairs(self.rel) do
        local title_item = r.kind == "title"
        items[i] = {
            id = r.id, kind = r.kind,
            label = title_item and title or r.label,
            checked = is_checked(r, st),
            enabled = title_item or is_enabled(r, st),
            x = self.x + r.x, y = self.y + r.y, w = r.w, h = r.h,
        }
    end
    return {
        x = self.x, y = self.y, w = self.w, h = self.h,
        items = items, font_px = Panel.LABEL_FONT_PX,
    }
end

-- An enabled button's id, "title" anywhere on the title bar outside
-- Close, "body" for the rest of the panel (gaps, padding, disabled
-- buttons), nil off the panel or while it is closed.  Enabled state is
-- the last state layout() saw.
function Panel:hit(lx, ly)
    if not self.opened then return nil end
    local rx, ry = lx - self.x, ly - self.y
    if rx < 0 or ry < 0 or rx >= self.w or ry >= self.h then return nil end
    for _, r in ipairs(self.rel) do
        if r.kind == "button" and rx >= r.x and rx < r.x + r.w
           and ry >= r.y and ry < r.y + r.h then
            return is_enabled(r, self.state) and r.id or "body"
        end
    end
    if ry < self.title_bar_h then return "title" end
    return "body"
end

-- The controller calls drag_begin for a drag that starts on the title
-- bar.  Returns nothing.
function Panel:drag_begin(lx, ly)
    if not self.opened then return end
    self.grab_dx, self.grab_dy = lx - self.x, ly - self.y
    self.dragging = true
end

-- Moves the panel with the finger, clamped as it goes so the painted
-- panel never shows a title bar the finger could not reach.  Returns true
-- when the panel moved, so an unmoved step needs no repaint.
function Panel:drag_move(lx, ly)
    if not (self.opened and self.dragging) then return false end
    local ox, oy = self.x, self.y
    self.x = round(lx - self.grab_dx)
    self.y = round(ly - self.grab_dy)
    self:_clamp_title()
    return self.x ~= ox or self.y ~= oy
end

-- lvx, lvy: the release velocity in px/s.  Only its magnitude matters, so
-- physical and logical velocities give the same answer.  A flick closes
-- the panel wherever the drag started; "flicked" means the panel is
-- closed after the call, so it is also the answer while already closed.
function Panel:drag_end(lvx, lvy)
    self.dragging = false
    if not self.opened then return "flicked" end
    if lvx * lvx + lvy * lvy >= self.flick_min * self.flick_min then
        self:close()
        return "flicked"
    end
    self:_clamp_title()
    return "stays"
end

-- The rotation changed.  The panel is re-measured for the new width and
-- brought fully back on screen: after a rotation the operator is looking
-- at a different layout, so a panel left hanging off an edge by an
-- earlier drag would only be partly visible for no reason.  A drag in
-- progress ends, because its grab offset belongs to the old orientation.
function Panel:set_screen(lw, lh)
    self.lw, self.lh = lw, lh
    self:_measure()
    self.dragging = false
    if self.opened then self:_clamp_full() end
end

return Panel
