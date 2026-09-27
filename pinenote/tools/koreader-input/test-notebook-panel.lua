--[[--
Host harness for the notebook's floating panel model (nb_panel.lua).

The panel is pure arithmetic in logical px, so this suite needs no
KOReader modules; it takes the bundle dir only to match the calling
convention of its siblings.  It checks:

  * the layout in both logical orientations (1404x1872 portrait, 1872x1404
    landscape) and on a narrow screen: every button at least
    panel_button_min_px, no overlaps, every item inside the panel, the
    panel inside the screen and within panel_max_w_px, labels short ASCII
    that fit their buttons, and the item ids the controller maps, in order;
  * wrapping when the width cap or the screen forces it;
  * checked and enabled states, and that state never moves an item;
  * hit testing: buttons, disabled buttons, the title bar, gaps, edges;
  * dragging: exact following, and a clamp that always leaves a reachable
    title bar, checked over a spread of drag targets;
  * flick versus stay at the flick_min_px_per_s threshold;
  * re-clamping on set_screen after a rotation.

Usage: luajit test-notebook-panel.lua <koreader_dir> <plugin_dir>
--]]

assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")

package.path = plugin_dir .. "/?.lua;" .. package.path

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label,
                        msg or ""))
    if not ok then fail = fail + 1 end
end

-- Purity: loading the panel must pull in nothing but itself.
local before = {}
for k in pairs(package.loaded) do before[k] = true end
local Panel = require("nb_panel")
local extra = {}
for k in pairs(package.loaded) do
    if not before[k] and k ~= "nb_panel" then extra[#extra + 1] = k end
end
table.sort(extra)
report(#extra == 0, "nb_panel loads no other module",
       #extra == 0 and "" or table.concat(extra, ","))

local cfg = dofile(plugin_dir .. "/nb_config.lua")
local MIN = cfg.panel_button_min_px
local MARGIN = cfg.panel_margin_px

local function with(over)
    local c = {}
    for k, v in pairs(cfg) do c[k] = v end
    for k, v in pairs(over) do c[k] = v end
    return c
end

local EXPECT_IDS = {
    "title", "close",
    "brush:fine", "brush:ballpoint", "brush:brushpen", "brush:marker",
    "brush:pencil", "brush:highlighter",
    "size:S", "size:M", "size:L",
    "mode:write", "mode:erase", "mode:stroke_erase",
    "rubber:area", "rubber:stroke",
    "undo", "redo", "page:prev", "page:next", "refresh",
    "nb:new", "nb:open", "nb:close",
}

local STATE = {
    brush = "pencil", size = "L", mode = "stroke_erase", rubber = "stroke",
    page = -3, can_undo = true, can_redo = false,
}

local PORTRAIT = { name = "portrait", lw = 1404, lh = 1872 }
local LANDSCAPE = { name = "landscape", lw = 1872, lh = 1404 }

local function by_id(L)
    local t = {}
    for _, it in ipairs(L.items) do t[it.id] = it end
    return t
end

local function rows_of(L)
    local ys, n = {}, 0
    for _, it in ipairs(L.items) do
        if not ys[it.y] then ys[it.y] = true; n = n + 1 end
    end
    return n
end

local function overlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w
       and a.y < b.y + b.h and b.y < a.y + a.h
end

-- The layout invariants.  `full` also demands the panel sit fully on
-- screen inside the margin (true after open and set_screen, not after a
-- drag); `fit` demands every label's estimated width fit its button and
-- the panel respect the width cap (neither holds when the cap is below
-- what the title row and the labels need).
local function check_layout(tag, L, lw, lh, full, fit)
    local errs = {}
    local function err(s) errs[#errs + 1] = s end

    local ids = {}
    for i, it in ipairs(L.items) do ids[i] = it.id end
    if table.concat(ids, ",") ~= table.concat(EXPECT_IDS, ",") then
        err("ids " .. table.concat(ids, ","))
    end
    for _, it in ipairs(L.items) do
        if it.kind == "button" and (it.w < MIN or it.h < MIN) then
            err(it.id .. " is " .. it.w .. "x" .. it.h)
        end
        if it.x < L.x or it.y < L.y or it.x + it.w > L.x + L.w
           or it.y + it.h > L.y + L.h then
            err(it.id .. " outside the panel")
        end
        if type(it.label) ~= "string" or not it.label:match("^[ -~]+$") then
            err(it.id .. " label not printable ASCII")
        elseif it.kind == "button" and #it.label > 15 then
            err(it.id .. " label too long: " .. it.label)
        elseif fit and it.kind == "button"
               and #it.label * Panel.LABEL_CHAR_PX + 2 * MARGIN > it.w then
            err(it.id .. " label does not fit: " .. it.label)
        end
    end
    for i = 1, #L.items do
        for j = i + 1, #L.items do
            if overlap(L.items[i], L.items[j]) then
                err(L.items[i].id .. " overlaps " .. L.items[j].id)
            end
        end
    end
    local b = by_id(L)
    if not (b.title and b.close and b.title.kind == "title"
            and b.close.y == b.title.y and b.close.x > b.title.x
            and b.title.w >= MIN) then
        err("title row is not title + Close")
    end
    if full then
        -- A panel wrapped taller than the screen (only on screens far
        -- smaller than the PineNote's) pins to the top margin, title first.
        local tall = L.h > lh - 2 * MARGIN
        if L.x < MARGIN or L.x + L.w > lw - MARGIN
           or (tall and L.y ~= MARGIN)
           or (not tall and (L.y < MARGIN or L.y + L.h > lh - MARGIN)) then
            err(string.format("panel %d,%d %dx%d not inside %dx%d less margin",
                              L.x, L.y, L.w, L.h, lw, lh))
        end
    end
    if fit then
        local cap = math.min(cfg.panel_max_w_px, lw - 2 * MARGIN)
        if L.w > cap then err("panel width " .. L.w .. " > cap " .. cap) end
    end
    report(#errs == 0, tag, errs[1] or string.format(
        "panel %d,%d %dx%d, %d rows", L.x, L.y, L.w, L.h, rows_of(L)))
end

------------------------------------------------------------------------
-- 1. Layout in both orientations, opened at the centre, the corners and
--    beyond the edges.
------------------------------------------------------------------------

for _, scr in ipairs({ LANDSCAPE, PORTRAIT }) do
    local lw, lh = scr.lw, scr.lh
    local pn = Panel.new(cfg)
    report(pn:layout(STATE) == nil, scr.name .. ": closed panel has no layout",
           "")
    pn:open(math.floor(lw / 2), math.floor(lh / 2), lw, lh)
    local L = pn:layout(STATE)
    check_layout(scr.name .. ": centred layout", L, lw, lh, true, true)
    local cx, cy = L.x + L.w / 2, L.y + L.h / 2
    report(math.abs(cx - lw / 2) <= 1 and math.abs(cy - lh / 2) <= 1,
           scr.name .. ": the panel centres on the long press",
           string.format("centre %.1f,%.1f", cx, cy))
    report(L.font_px == Panel.LABEL_FONT_PX, scr.name .. ": layout names its font size",
           tostring(L.font_px))

    local spots = {
        { 0, 0 }, { lw - 1, 0 }, { 0, lh - 1 }, { lw - 1, lh - 1 },
        { -400, -400 }, { lw + 400, lh + 400 }, { lw / 2, -50 },
    }
    for _, s in ipairs(spots) do
        pn:open(s[1], s[2], lw, lh)
        check_layout(string.format("%s: opened at %d,%d", scr.name, s[1], s[2]),
                     pn:layout(STATE), lw, lh, true, true)
    end
end

do
    -- Both orientations must give the same panel on the PineNote (the cap,
    -- not the screen, sets the width) so a rotation does not reflow it.
    local a, b = Panel.new(cfg), Panel.new(cfg)
    a:open(0, 0, LANDSCAPE.lw, LANDSCAPE.lh)
    b:open(0, 0, PORTRAIT.lw, PORTRAIT.lh)
    local La, Lb = a:layout(STATE), b:layout(STATE)
    report(La.w == Lb.w and La.h == Lb.h, "same panel size in both orientations",
           La.w .. "x" .. La.h .. " vs " .. Lb.w .. "x" .. Lb.h)
end

do
    -- Refresh (a wash of the page on the glass) sits in the page row after
    -- Next, and is enabled whatever the state: it writes nothing.
    for _, scr in ipairs({ LANDSCAPE, PORTRAIT }) do
        local pn = Panel.new(cfg)
        pn:open(0, 0, scr.lw, scr.lh)
        for _, st in ipairs({ STATE, { page = 0 } }) do
            local b = by_id(pn:layout(st))
            local r, n = b.refresh, b["page:next"]
            report(r and r.label == "Refresh" and r.enabled and r.y == b.undo.y
                   and r.x > n.x and pn:hit(r.x + 1, r.y + 1) == "refresh",
                   scr.name .. ": Refresh is in the page row after Next, enabled",
                   r and string.format("%d,%d %dx%d", r.x, r.y, r.w, r.h) or "missing")
        end
    end
end

------------------------------------------------------------------------
-- 2. Wrapping.
------------------------------------------------------------------------

do
    local function brush_rows(L)
        local ys, n = {}, 0
        for _, it in ipairs(L.items) do
            if it.id:match("^brush:") and not ys[it.y] then
                ys[it.y] = true; n = n + 1
            end
        end
        return n
    end

    local wide = Panel.new(cfg)
    wide:open(0, 0, LANDSCAPE.lw, LANDSCAPE.lh)
    local Lw = wide:layout(STATE)
    report(brush_rows(Lw) == 1, "default cap: the brushes share one row",
           brush_rows(Lw) .. " row(s)")

    local capped = Panel.new(with{ panel_max_w_px = 420 })
    capped:open(0, 0, LANDSCAPE.lw, LANDSCAPE.lh)
    local Lc = capped:layout(STATE)
    check_layout("cap 420: wrapped layout", Lc, LANDSCAPE.lw, LANDSCAPE.lh, true,
                 false)
    report(Lc.w <= 420 and brush_rows(Lc) >= 2,
           "cap 420: the brushes wrap within the cap",
           Lc.w .. " px wide, " .. brush_rows(Lc) .. " brush rows")

    local narrow = Panel.new(cfg)
    narrow:open(240, 400, 480, 800)
    local Ln = narrow:layout(STATE)
    check_layout("480x800 screen: wrapped layout", Ln, 480, 800, true, true)
    report(Ln.w <= 480 - 2 * MARGIN and brush_rows(Ln) >= 2,
           "480x800 screen: the screen width wraps the rows",
           Ln.w .. " px wide, " .. brush_rows(Ln) .. " brush rows")
    report(Ln.h > 800 - 2 * MARGIN and Ln.y == MARGIN,
           "480x800 screen: a panel taller than the screen pins to the top",
           Ln.h .. " px tall at y " .. Ln.y)

    -- A cap below what the title row needs: the minimum sizes win and
    -- the label estimate is allowed to overrun (the glue truncates).
    local tiny = Panel.new(with{ panel_max_w_px = 100 })
    tiny:open(0, 0, LANDSCAPE.lw, LANDSCAPE.lh)
    local Lt = tiny:layout(STATE)
    check_layout("cap 100: minimum sizes beat the cap", Lt, LANDSCAPE.lw,
                 LANDSCAPE.lh, true, false)
end

------------------------------------------------------------------------
-- 3. Checked and enabled states; titles.
------------------------------------------------------------------------

do
    local pn = Panel.new(cfg)
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)

    local function states(L)
        local checked, disabled = {}, {}
        for _, it in ipairs(L.items) do
            if it.checked then checked[#checked + 1] = it.id end
            if not it.enabled then disabled[#disabled + 1] = it.id end
        end
        return table.concat(checked, ","), table.concat(disabled, ",")
    end

    local L1 = pn:layout(STATE)
    local c, d = states(L1)
    report(c == "brush:pencil,size:L,mode:stroke_erase,rubber:stroke",
           "checked follows brush, size, mode and rubber", c)
    report(d == "redo", "redo disabled without a redo target", d)
    report(by_id(L1).title.label == "Notebook - page -3",
           "title names the page, negative included", by_id(L1).title.label)

    local L2 = pn:layout{
        brush = "fine", size = "S", mode = "write", rubber = "area",
        page = 12, can_undo = false, can_redo = true, nb_title = "Sketches",
    }
    c, d = states(L2)
    report(c == "brush:fine,size:S,mode:write,rubber:area",
           "checked moves with the state", c)
    report(d == "undo", "undo disabled without an undo target", d)
    report(by_id(L2).title.label == "Sketches - page 12",
           "title uses the notebook's title", by_id(L2).title.label)

    local L3 = pn:layout{ page = 1 }
    c, d = states(L3)
    report(c == "" and d == "undo,redo",
           "an empty state checks nothing and disables undo/redo",
           "checked={" .. c .. "} disabled={" .. d .. "}")

    local same = true
    for i, it in ipairs(L1.items) do
        local o, p = L2.items[i], L3.items[i]
        if it.x ~= o.x or it.y ~= o.y or it.w ~= o.w or it.h ~= o.h
           or it.x ~= p.x or it.y ~= p.y or it.w ~= p.w or it.h ~= p.h then
            same = false
        end
    end
    report(same and L1.w == L2.w and L1.h == L3.h,
           "state never moves or resizes an item", "")

    L1.items[3].x = -999
    report(pn:layout(STATE).items[3].x ~= -999,
           "each layout returns fresh tables", "")
end

------------------------------------------------------------------------
-- 4. Hit testing.
------------------------------------------------------------------------

do
    local pn = Panel.new(cfg)
    report(pn:hit(10, 10) == nil, "hit on a never-opened panel is nil", "")
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
    local L = pn:layout(STATE)
    local b = by_id(L)

    local bad
    for _, it in ipairs(L.items) do
        if it.kind == "button" then
            local want = it.enabled and it.id or "body"
            local probes = {
                { it.x + math.floor(it.w / 2), it.y + math.floor(it.h / 2) },
                { it.x, it.y }, { it.x + it.w - 1, it.y + it.h - 1 },
            }
            for _, p in ipairs(probes) do
                local got = pn:hit(p[1], p[2])
                if not bad and got ~= want then
                    bad = string.format("%s at %d,%d -> %s", it.id, p[1], p[2],
                                        tostring(got))
                end
            end
        end
    end
    report(not bad, "every button hits by its centre and corners",
           bad or "enabled -> id, disabled -> body")
    report(pn:hit(b.redo.x + 5, b.redo.y + 5) == "body",
           "a disabled button is body", "redo")

    local cases = {
        { "title centre", b.title.x + math.floor(b.title.w / 2),
          b.title.y + math.floor(b.title.h / 2), "title" },
        { "title bar top padding", L.x + 2, L.y + 2, "title" },
        { "title bar gap before Close", b.close.x - 1, b.close.y + 5, "title" },
        { "title bar right of Close", L.x + L.w - 2, b.close.y + 5, "title" },
        { "gap between brushes", b["brush:fine"].x + b["brush:fine"].w,
          b["brush:fine"].y + 10, "body" },
        { "bottom padding", L.x + 5, L.y + L.h - 1, "body" },
        { "left of the panel", L.x - 1, L.y + 10, nil },
        { "right of the panel", L.x + L.w, L.y + 10, nil },
        { "below the panel", L.x + 10, L.y + L.h, nil },
        { "above the panel", L.x + 10, L.y - 1, nil },
    }
    for _, cs in ipairs(cases) do
        local got = pn:hit(cs[2], cs[3])
        report(got == cs[4], "hit: " .. cs[1], tostring(got))
    end

    pn:close()
    report(not pn:is_open() and pn:hit(b.close.x + 5, b.close.y + 5) == nil
           and pn:layout(STATE) == nil,
           "a closed panel hits nothing and has no layout", "")
end

------------------------------------------------------------------------
-- 5. Dragging.
------------------------------------------------------------------------

-- The part of the title bar left on screen after a drag: the strip above
-- the first group, from the panel's left edge to Close.
local function visible_title(L, lw, lh)
    local b = by_id(L)
    local x0, x1 = math.max(L.x, 0), math.min(b.close.x, lw)
    local y0, y1 = math.max(L.y, 0), math.min(b.title.y + b.title.h, lh)
    return x0, y0, x1 - x0, y1 - y0
end

for _, scr in ipairs({ LANDSCAPE, PORTRAIT }) do
    local lw, lh = scr.lw, scr.lh
    local pn = Panel.new(cfg)
    pn:open(math.floor(lw / 2), math.floor(lh / 2), lw, lh)
    local L0 = pn:layout(STATE)
    local t = by_id(L0).title
    local gx, gy = t.x + 40, t.y + 20

    report(pn:hit(gx, gy) == "title", scr.name .. ": the drag starts on the title",
           "")
    pn:drag_begin(gx, gy)
    local moved = pn:drag_move(gx + 100, gy + 50)
    local L1 = pn:layout(STATE)
    report(moved and L1.x == L0.x + 100 and L1.y == L0.y + 50,
           scr.name .. ": the panel follows the finger exactly",
           string.format("%d,%d -> %d,%d", L0.x, L0.y, L1.x, L1.y))
    report(pn:drag_move(gx + 100, gy + 50) == false,
           scr.name .. ": an unmoved step reports no move", "")

    -- Named extremes, then a spread of targets: after every step the title
    -- bar keeps its full height and at least a grab's width on screen, and
    -- a touch there still hits "title".  The extremes must stop exactly at
    -- that limit: the title bar grab_px wide at a side edge, or flush with
    -- the top or the bottom.
    local keep = 2 * MIN
    local function at_edge(L, edge)
        local b = by_id(L)
        if edge == "left" then return b.close.x == keep end
        if edge == "right" then return L.x == lw - keep end
        if edge == "top" then return L.y == 0 end
        return b.title.y + b.title.h == lh
    end
    local targets = {
        { "far left", -5000, gy, "left" }, { "far right", 5000, gy, "right" },
        { "far up", gx, -5000, "top" }, { "far down", gx, 5000, "bottom" },
        { "bottom-left corner", -5000, 5000, "left", "bottom" },
        { "top-right corner", 5000, -5000, "right", "top" },
    }
    local n_named = #targets
    local seed = 7
    for i = 1, 300 do
        seed = (seed * 16807) % 2147483647
        local x = seed % (lw + 4000) - 2000
        seed = (seed * 16807) % 2147483647
        local y = seed % (lh + 4000) - 2000
        targets[#targets + 1] = { "spread " .. i, x, y }
    end
    local bad, off_screen = nil, 0
    for i, tg in ipairs(targets) do
        pn:drag_move(tg[2], tg[3])
        local L = pn:layout(STATE)
        local vx, vy, vw, vh = visible_title(L, lw, lh)
        local b = by_id(L)
        local full_h = b.title.y + b.title.h - L.y
        local hit = pn:hit(vx + math.floor(vw / 2), vy + math.floor(vh / 2))
        if L.x < 0 or L.x + L.w > lw or L.y + L.h > lh then
            off_screen = off_screen + 1
        end
        local ok = vw >= keep and vh == full_h and hit == "title"
        if not ok and not bad then
            bad = string.format("%s: panel at %d,%d, title %dx%d visible, hit %s",
                                tg[1], L.x, L.y, vw, vh, tostring(hit))
        end
        if i <= n_named then
            local edges_ok = at_edge(L, tg[4]) and (not tg[5] or at_edge(L, tg[5]))
            report(edges_ok, scr.name .. ": a drag " .. tg[1] .. " stops at the limit",
                   string.format("panel %d,%d", L.x, L.y))
        end
    end
    report(not bad, scr.name .. ": every drag leaves the title bar reachable",
           bad or (#targets .. " targets"))
    report(off_screen > 0,
           scr.name .. ": a drag may push the rest of the panel off screen",
           off_screen .. " of " .. #targets .. " positions")

    -- A slow release stays where the drag left it.
    pn:drag_move(gx - 5000, gy + 5000)
    local Lb = pn:layout(STATE)
    local res = pn:drag_end(200, -300)
    local La = pn:layout(STATE)
    report(res == "stays" and pn:is_open() and La.x == Lb.x and La.y == Lb.y,
           scr.name .. ": a slow release stays", tostring(res))
    report(pn:drag_move(0, 0) == false,
           scr.name .. ": a move after the release does nothing", "")
end

------------------------------------------------------------------------
-- 6. Flick versus stay.
------------------------------------------------------------------------

do
    local F = cfg.flick_min_px_per_s
    local cases = {
        { F, 0, "flicked" },
        { F - 0.1, 0, "stays" },
        { 0, -F, "flicked" },
        { -F, 0, "flicked" },
        { 900, 1200, "flicked" },   -- exactly 1500 px/s diagonally
        { 900, 1199, "stays" },
        { 0, 0, "stays" },
    }
    for _, cs in ipairs(cases) do
        local pn = Panel.new(cfg)
        pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
        pn:layout(STATE)
        pn:drag_begin(900, 450)
        pn:drag_move(950, 470)
        local res = pn:drag_end(cs[1], cs[2])
        local open_ok = (res == "stays") == pn:is_open()
        report(res == cs[3] and open_ok,
               string.format("release at %s,%s px/s %s", tostring(cs[1]),
                             tostring(cs[2]), cs[3]),
               tostring(res) .. (pn:is_open() and ", open" or ", closed"))
    end

    local pn = Panel.new(cfg)
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
    pn:drag_end(F, 0)
    report(pn:layout(STATE) == nil and pn:hit(900, 700) == nil,
           "a flicked panel is gone", "")
    report(pn:drag_end(0, 0) == "flicked",
           "a release on a closed panel reports it closed", "")
end

------------------------------------------------------------------------
-- 7. Rotation: set_screen re-measures and re-clamps.
------------------------------------------------------------------------

do
    local pn = Panel.new(cfg)
    pn:open(LANDSCAPE.lw - 1, LANDSCAPE.lh - 1, LANDSCAPE.lw, LANDSCAPE.lh)
    local L0 = pn:layout(STATE)
    pn:set_screen(PORTRAIT.lw, PORTRAIT.lh)
    local L1 = pn:layout(STATE)
    check_layout("bottom-right landscape panel after rotating to portrait", L1,
                 PORTRAIT.lw, PORTRAIT.lh, true, true)
    report(L1.x == PORTRAIT.lw - MARGIN - L1.w and L1.y == L0.y,
           "rotation keeps what still fits and pulls in the rest",
           string.format("%d,%d -> %d,%d", L0.x, L0.y, L1.x, L1.y))

    -- A panel dragged half off screen comes fully back on a rotation.
    local t = by_id(L1).title
    pn:drag_begin(t.x + 10, t.y + 10)
    pn:drag_move(-5000, t.y + 10)
    local Ld = pn:layout(STATE)
    pn:drag_end(0, 0)
    pn:set_screen(LANDSCAPE.lw, LANDSCAPE.lh)
    local L2 = pn:layout(STATE)
    check_layout("dragged-off panel after rotating to landscape", L2,
                 LANDSCAPE.lw, LANDSCAPE.lh, true, true)
    report(Ld.x < 0 and L2.x == MARGIN,
           "rotation brings a dragged-off panel back inside the margin",
           Ld.x .. " -> " .. L2.x)

    -- A rotation onto a narrower screen reflows the panel.
    pn:set_screen(480, 800)
    check_layout("rotation onto a 480x800 screen", pn:layout(STATE), 480, 800,
                 true, true)

    -- A rotation mid-drag ends the drag: its grab offset was in the old
    -- orientation.
    pn:set_screen(LANDSCAPE.lw, LANDSCAPE.lh)
    local L3 = pn:layout(STATE)
    local tt = by_id(L3).title
    pn:drag_begin(tt.x + 10, tt.y + 10)
    pn:set_screen(PORTRAIT.lw, PORTRAIT.lh)
    local L4 = pn:layout(STATE)
    report(pn:drag_move(tt.x + 300, tt.y + 300) == false
           and pn:layout(STATE).x == L4.x,
           "a rotation ends a drag in progress", "")

    -- Closed: set_screen only records the size.
    local closed = Panel.new(cfg)
    closed:set_screen(PORTRAIT.lw, PORTRAIT.lh)
    report(not closed:is_open() and closed:layout(STATE) == nil,
           "set_screen on a closed panel leaves it closed", "")

    -- A half turn (mode 1 to 3) keeps the logical size, but the finger's
    -- logical position flips, so the drag still ends; an on-screen panel
    -- keeps its place.
    local half = Panel.new(cfg)
    half:open(300, 400, PORTRAIT.lw, PORTRAIT.lh)
    local Lh0 = half:layout(STATE)
    local ht = by_id(Lh0).title
    half:drag_begin(ht.x + 10, ht.y + 10)
    half:set_screen(PORTRAIT.lw, PORTRAIT.lh)
    local Lh1 = half:layout(STATE)
    report(half:drag_move(ht.x + 200, ht.y + 200) == false
           and Lh1.x == Lh0.x and Lh1.y == Lh0.y,
           "a half turn ends the drag and keeps the panel's place",
           string.format("%d,%d -> %d,%d", Lh0.x, Lh0.y, Lh1.x, Lh1.y))
end

------------------------------------------------------------------------
-- 8. Adversarial: exact edges, drag lifecycle, odd inputs, and a sweep
--    of configs and screens.
------------------------------------------------------------------------

do
    local pn = Panel.new(cfg)
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
    local L = pn:layout(STATE)
    local b = by_id(L)
    local first = b["brush:fine"]
    local cases = {
        { "last row of the title bar", L.x + 2, first.y - MARGIN - 1, "title" },
        { "first row below the title bar", L.x + 2, first.y - MARGIN, "body" },
        { "Close's left edge", b.close.x, b.close.y, "close" },
        { "Close's right edge", b.close.x + b.close.w - 1, b.close.y, "close" },
        { "past Close's right edge", b.close.x + b.close.w, b.close.y, "title" },
        { "above Close, in the padding", b.close.x + 5, b.close.y - 1, "title" },
        { "below Close", b.close.x + 5, b.close.y + b.close.h, "body" },
        { "the panel's last pixel", L.x + L.w - 1, L.y + L.h - 1, "body" },
        { "a fractional point on a button", first.x + 0.5, first.y + 0.25,
          "brush:fine" },
        { "a fractional point just off the panel", L.x - 0.5, L.y + 10, nil },
    }
    for _, cs in ipairs(cases) do
        local got = pn:hit(cs[2], cs[3])
        report(got == cs[4], "hit: " .. cs[1], tostring(got))
    end

    -- hit() follows the latest layout's enabled state.
    local was = pn:hit(b.redo.x + 5, b.redo.y + 5)
    pn:layout{ can_undo = true, can_redo = true, page = 1 }
    local now = pn:hit(b.redo.x + 5, b.redo.y + 5)
    report(was == "body" and now == "redo",
           "redo becomes hittable once a layout enables it",
           tostring(was) .. " -> " .. tostring(now))

    local labels = {}
    for _, pg in ipairs({ 0, -1, 2 ^ 40, -2 ^ 31 - 1 }) do
        labels[#labels + 1] = by_id(pn:layout{ page = pg }).title.label
    end
    labels[#labels + 1] = by_id(pn:layout{}).title.label
    local s = table.concat(labels, "|")
    report(s == "Notebook - page 0|Notebook - page -1|Notebook - page 1099511627776"
           .. "|Notebook - page -2147483649|Notebook - page ?",
           "page labels: zero, negative, huge and missing", s)
end

do
    -- The drag lifecycle out of order.
    local L0
    local function fresh()
        local pn = Panel.new(cfg)
        pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
        L0 = pn:layout(STATE)
        return pn, by_id(L0).title
    end

    local pn = Panel.new(cfg)
    pn:drag_begin(10, 10)
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
    report(pn:drag_move(400, 400) == false,
           "a drag_begin on a closed panel does not survive its opening", "")

    local t
    pn, t = fresh()
    pn:drag_begin(t.x + 5, t.y + 5)
    pn:close()
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
    report(pn:drag_move(t.x + 300, t.y + 300) == false,
           "closing ends a drag; reopening does not resume it", "")

    pn, t = fresh()
    pn:drag_begin(t.x + 5, t.y + 5)
    pn:open(200, 200, LANDSCAPE.lw, LANDSCAPE.lh)
    report(pn:drag_move(t.x + 300, t.y + 300) == false,
           "reopening mid-drag ends the drag", "")

    pn = fresh()
    local res = pn:drag_end(10, 10)
    local L1 = pn:layout(STATE)
    report(res == "stays" and L1.x == L0.x and L1.y == L0.y,
           "a slow drag_end without drag_begin moves nothing", tostring(res))
    report(pn:drag_end(0, -cfg.flick_min_px_per_s) == "flicked" and not pn:is_open(),
           "a fast drag_end without drag_begin flicks", "")

    pn, t = fresh()
    pn:drag_begin(t.x + 5, t.y + 5)
    pn:drag_move(-5000, t.y + 5)
    local La = pn:layout(STATE)
    report(pn:drag_move(-6000, t.y + 5) == false
           and pn:layout(STATE).x == La.x,
           "pushing past the clamp is an unmoved step", "")

    pn = fresh()
    report(pn:drag_end(1 / 0, 0) == "flicked", "an infinite release flicks", "")
    pn = fresh()
    report(pn:drag_end(0 / 0, 0 / 0) == "stays" and pn:is_open(),
           "a NaN release stays rather than closing on garbage", "")

    pn = fresh()
    pn:drag_end(cfg.flick_min_px_per_s, 0)
    pn:open(1000, 800, LANDSCAPE.lw, LANDSCAPE.lh)
    local L2 = pn:layout(STATE)
    report(pn:is_open() and L2.x == 1000 - L2.w / 2 and L2.y == 800 - L2.h / 2,
           "a flicked panel reopens centred on the new long press",
           string.format("%d,%d", L2.x, L2.y))
end

do
    -- Margin 0: adjacent buttons share an edge, and the half-open hit
    -- boxes give the shared column to the right-hand button.
    local pn = Panel.new(with{ panel_margin_px = 0 })
    pn:open(900, 700, LANDSCAPE.lw, LANDSCAPE.lh)
    local L = pn:layout(STATE)
    check_layout("margin 0: layout", L, LANDSCAPE.lw, LANDSCAPE.lh, true, false)
    local b = by_id(L)
    local fine, ball = b["brush:fine"], b["brush:ballpoint"]
    report(fine.x + fine.w == ball.x
           and pn:hit(ball.x - 1, ball.y + 5) == "brush:fine"
           and pn:hit(ball.x, ball.y + 5) == "brush:ballpoint",
           "margin 0: a shared edge belongs to one button",
           tostring(pn:hit(ball.x, ball.y + 5)))
end

do
    -- A deterministic sweep of configs and screens: every invariant, a
    -- hit at every item's centre, and random drags that must leave the
    -- title bar reachable.
    local seed = 20260926
    local function rnd(n)
        seed = (seed * 16807) % 2147483647
        return seed % n
    end
    local bad, n = nil, 0
    local function note(s) if not bad then bad = s end end
    for trial = 1, 400 do
        local c = with{
            panel_button_min_px = 20 + rnd(200), panel_margin_px = rnd(40),
            panel_max_w_px = 50 + rnd(2500),
        }
        local lw, lh = 100 + rnd(2500), 100 + rnd(2500)
        local m, min = c.panel_margin_px, c.panel_button_min_px
        local tag = string.format("trial %d (min %d, margin %d, cap %d, %dx%d)",
                                  trial, min, m, c.panel_max_w_px, lw, lh)
        local pn = Panel.new(c)
        pn:open(rnd(lw + 400) - 200, rnd(lh + 400) - 200, lw, lh)
        local L = pn:layout{ can_undo = true, can_redo = true, page = 1 }
        for i, it in ipairs(L.items) do
            n = n + 1
            if it.kind == "button" and (it.w < min or it.h < min) then
                note(tag .. ": " .. it.id .. " is " .. it.w .. "x" .. it.h)
            end
            if it.x < L.x or it.y < L.y or it.x + it.w > L.x + L.w
               or it.y + it.h > L.y + L.h then
                note(tag .. ": " .. it.id .. " outside the panel")
            end
            for j = i + 1, #L.items do
                if overlap(it, L.items[j]) then
                    note(tag .. ": " .. it.id .. " overlaps " .. L.items[j].id)
                end
            end
            local want = it.kind == "title" and "title" or it.id
            local got = pn:hit(it.x + math.floor(it.w / 2), it.y + math.floor(it.h / 2))
            if got ~= want then
                note(tag .. ": " .. it.id .. " centre hits " .. tostring(got))
            end
        end
        if L.w <= lw - 2 * m and (L.x < m or L.x + L.w > lw - m) then
            note(tag .. ": panel x " .. L.x .. " off screen")
        end
        if L.h <= lh - 2 * m and (L.y < m or L.y + L.h > lh - m) then
            note(tag .. ": panel y " .. L.y .. " off screen")
        end
        if (L.w > lw - 2 * m and L.x ~= m) or (L.h > lh - 2 * m and L.y ~= m) then
            note(tag .. ": an oversized panel is not pinned to the margin")
        end

        local t = by_id(L).title
        local title_h = t.y + t.h - L.y
        pn:drag_begin(t.x + 1, t.y + 1)
        for _ = 1, 12 do
            pn:drag_move(rnd(lw + 6000) - 3000, rnd(lh + 6000) - 3000)
            local Ld = pn:layout{}
            local vx, vy, vw, vh = visible_title(Ld, lw, lh)
            local want_w = math.min(2 * min, by_id(Ld).close.x - Ld.x, lw)
            if vw < want_w or vh < math.min(title_h, lh) then
                note(string.format("%s: drag to %d,%d leaves %dx%d of the title",
                                   tag, Ld.x, Ld.y, vw, vh))
            elseif pn:hit(vx + math.floor(vw / 2), vy + math.floor(vh / 2)) ~= "title" then
                note(tag .. ": the visible title bar does not hit title")
            end
        end
    end
    report(not bad, "sweep: 400 configs and screens keep every invariant",
           bad or (n .. " items"))
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
