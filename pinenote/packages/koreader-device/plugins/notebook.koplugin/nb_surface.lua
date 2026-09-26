--[[--
nb_surface -- the notebook's pixels: the page buffer, the framebuffer
alias, and the painter that turns the controller's ink and render_page
commands into Blitbuffer writes.

Not pure like the other nb_ modules: it needs the bundle's ffi/blitbuffer
(and ffi/png, loaded only by write_png).  It loads no UI module, so
pinenote/tools/koreader-input/test-notebook-render.lua runs it headless
on the host bundle, and notebook-replay.lua renders real captures with it.

Every buffer ink and render_page paint is PHYSICAL, rotation 0: the page
buffer (BB8, W x H, one per notebook window) and the framebuffer alias (a
rotation-0 view of Screen.bb's memory).  Spans arrive in physical px
already clipped to the panel, so row y starts at data + stride * y and
no coordinate is transformed.  blit_page and blit_panel are paintTo's:
they write Screen.bb in its own rotation.

Compositing (the stroke's style.comp):

  * black, white -- a C fill per row through paintRect;
  * darken       -- black only where nb_brush.mask() is true; other
                    pixels are left as they were, so overlapping strokes
                    and repeated rows are idempotent.  paintRect cannot
                    mask, so the black pixels are written through a row
                    pointer for BB8 and RGB16 (the device framebuffer is
                    RGB16); any other type goes through setPixel.

Every nb_brush pattern repeats every 4 px along both axes (Bayer 4x4, and
the checker's period 2), so the mask is sampled once into a 4x4 tile per
(pattern, density), and a row is one loop over its pixels that keeps or
blackens each by its residue x % 4 with a mask and an or: no per-pixel
call and no per-pixel branch.  The row is deliberately not a short
stride-4 loop per residue: LuaJIT aborts traces that start in such a
nested short loop until it blacklists it, and the loop then runs in the
interpreter for the rest of the process (about 5x slower for the
highlighter, measured on the host after other brushes had drawn).
test-notebook-render.lua checks the darkened pixels against Brush.mask
pixel by pixel, so a new pattern that breaks the period shows up there.

Night mode: Screen.bb's inverse flag makes every paint through it write
the inverted value, and the alias copies the flag, so live ink is drawn
inverted.  The page buffer is never inverted.  KOReader's C blitter only
runs on matching flags and then copies memory unchanged, which would put
un-inverted page memory next to inverted live ink (black ink written as
0xFF onto 0xFF paper: invisible).  blit_page therefore copies with the C
blitter and, when the flags differ, inverts the copied rect in place; the
result is what KOReader's per-pixel Lua fallback gives, at C speed.  With
the C blitter off, blit_page leaves the flags unmatched and that fallback
does the work.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Brush = require("nb_brush")
local ffi = require("ffi")

local Surface = {}

local C_BLACK, C_WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local TYPE_BB8, TYPE_BBRGB16 = Blitbuffer.TYPE_BB8, Blitbuffer.TYPE_BBRGB16
local TYPE_BBRGB24 = Blitbuffer.TYPE_BBRGB24
local U8P = ffi.typeof("uint8_t *")
local U16P = ffi.typeof("uint16_t *")
local band, bor = bit.band, bit.bor

------------------------------------------------------------------------
-- The painter.  Its state is set at the start of each public call and
-- read by the row functions; nothing here re-enters a public call, so
-- one set of upvalues serves every call without a closure per span.
-- The call drops its buffer at the end (release), so a closed window's
-- page is not kept alive by the last stroke drawn into it.
------------------------------------------------------------------------

local P_bb            -- the target buffer (rotation 0)
local P_kind          -- 1: BB8 pointer, 2: RGB16 pointer, 0: setPixel
local P_base, P_stride
local P_w, P_h        -- its physical size, which darken_row clips to
local P_black         -- the memory value of black, after the inverse flag
local P_fill          -- the Color8 of a black or white fill
local P_pat           -- the darken pattern
local P_row           -- fill_row or darken_row

-- The 4x4 mask tile, [(y % 4) * 4 + x % 4 + 1], for tile_pat at
-- tile_dens.  Pressure moves the density per segment, so a render
-- resamples it when either changes.
local TILE = {}
local tile_pat, tile_dens
local MASK_STYLE = {}
-- One row's residues as darken_row applies them: a pixel becomes
-- (old & KEEP[x % 4]) | SET[x % 4], so an inked residue is black and the
-- others keep what they had.
local KEEP = ffi.new("uint32_t[4]")
local SET = ffi.new("uint32_t[4]")

local function set_tile(pat, dens)
    MASK_STYLE.pat = pat
    for yy = 0, 3 do
        for k = 0, 3 do
            TILE[yy * 4 + k + 1] = Brush.mask(MASK_STYLE, dens, k, yy)
        end
    end
    tile_pat, tile_dens = pat, dens
end

local function fill_row(y, x0, x1)
    P_bb:paintRect(x0, y, x1 - x0 + 1, 1, P_fill)
end

local function darken_row(y, x0, x1, dens)
    -- paintRect clips a fill to the buffer; the pointer and setPixel
    -- writes below check nothing, so a span past the buffer (a caller
    -- whose W and H disagree with it) would land in the next row or past
    -- the framebuffer's mapping.  Clip here, as a fill would be clipped.
    if y < 0 or y >= P_h then return end
    if x0 < 0 then x0 = 0 end
    if x1 >= P_w then x1 = P_w - 1 end
    if x1 < x0 then return end
    if dens ~= tile_dens or P_pat ~= tile_pat then set_tile(P_pat, dens) end
    local t = (y % 4) * 4 + 1
    if P_kind == 0 then
        local bb = P_bb
        for x = x0, x1 do
            if TILE[t + x % 4] then bb:setPixel(x, y, C_BLACK) end
        end
        return
    end
    local m0, m1, m2, m3 = TILE[t], TILE[t + 1], TILE[t + 2], TILE[t + 3]
    -- A sparse Bayer level leaves whole rows of the tile empty.
    if not (m0 or m1 or m2 or m3) then return end
    -- Unrolled, not a loop over k, for the reason in the module header.
    local v = P_black
    KEEP[0], SET[0] = m0 and 0 or 0xFFFF, m0 and v or 0
    KEEP[1], SET[1] = m1 and 0 or 0xFFFF, m1 and v or 0
    KEEP[2], SET[2] = m2 and 0 or 0xFFFF, m2 and v or 0
    KEEP[3], SET[3] = m3 and 0 or 0xFFFF, m3 and v or 0
    local p = P_base + P_stride * y
    if P_kind == 2 then p = ffi.cast(U16P, p) end
    for x = x0, x1 do
        local k = band(x, 3)
        p[x] = bor(band(p[x], KEEP[k]), SET[k])
    end
end

local function set_target(bb)
    P_bb = bb
    local t, inv = bb:getType(), bb:getInverse() == 1
    if t == TYPE_BB8 then
        P_kind, P_black = 1, inv and 0xFF or 0x00
    elseif t == TYPE_BBRGB16 then
        P_kind, P_black = 2, inv and 0xFFFF or 0x0000
    else
        P_kind, P_black = 0, nil
    end
    P_base, P_stride = ffi.cast(U8P, bb.data), bb.stride
    P_w, P_h = bb.w, bb.h
end

local function release()
    P_bb, P_base = nil, nil
end

-- Returns false for a comp this build does not draw.  Only a damaged or
-- newer journal line can carry one, and such a stroke draws nothing
-- rather than taking the reader down.
local function set_style(comp, pat)
    -- The solid mask is every pixel, so darken with it is a black fill,
    -- and takes the C fill rather than the per-pixel path.
    if comp == "black" or (comp == "darken" and pat == "solid") then
        P_row, P_fill = fill_row, C_BLACK
    elseif comp == "white" then
        P_row, P_fill = fill_row, C_WHITE
    elseif comp == "darken" then
        P_row, P_pat = darken_row, pat
    else
        return false
    end
    return true
end

------------------------------------------------------------------------
-- Buffers
------------------------------------------------------------------------

--- A W x H BB8 page, rotation 0, white.  BB.new calloc-zeroes, which is
--- black, so it is filled.
function Surface.new_page(W, H)
    local bb = Blitbuffer.new(W, H, TYPE_BB8)
    bb:fill(C_WHITE)
    return bb
end

--- A rotation-0 view of screen_bb's memory, so ink is written in
--- physical px whatever the KOReader rotation.  It owns nothing and is
--- never freed.  Build it at each open: Screen.bb is not to be cached.
function Surface.fb_alias(s)
    local bb = Blitbuffer.new(s.w, s.h, s:getType(), s.data, s.stride,
                              s.pixel_stride)
    bb:setInverse(s:getInverse())
    return bb
end

------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------

--- One controller ink command into bb (rotation 0).  exclude, when
--- given, is a physical {x, y, w, h} left untouched: the open panel's
--- rect on the framebuffer, whose pixels the page buffer does not hold.
function Surface.ink(bb, cmd, exclude)
    if not set_style(cmd.comp, cmd.pat) then return end
    set_target(bb)
    local row, dens, spans = P_row, cmd.dens, cmd.spans
    local ex0, ex1, ey0, ey1
    if exclude and exclude.w > 0 and exclude.h > 0 then
        ex0, ey0 = exclude.x, exclude.y
        ex1, ey1 = ex0 + exclude.w - 1, ey0 + exclude.h - 1
    end
    for i = 1, #spans, 3 do
        local y, x0, x1 = spans[i], spans[i + 1], spans[i + 2]
        if ex0 and y >= ey0 and y <= ey1 and x1 >= ex0 and x0 <= ex1 then
            if x0 < ex0 then row(y, x0, ex0 - 1, dens) end
            if x1 > ex1 then row(y, ex1 + 1, x1, dens) end
        else
            row(y, x0, x1, dens)
        end
    end
    release()
end

-- Brush.bbox of a replayed entry, computed once per entry: every region
-- render rejects the strokes outside its region by it, and recomputing
-- it walked every sample on the page each time.  J.replay and J.apply
-- build an entry's style and points once and never change them; the
-- keys are weak, so a page dropped takes its boxes with it.
local BOXES = setmetatable({}, { __mode = "k" })

local function entry_box(e)
    local b = BOXES[e]
    if not b then
        local x0, y0, x1, y1 = Brush.bbox(e.style, e.points)
        b = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
        BOXES[e] = b
    end
    return b
end

--- Rebuild bb from a page's strokes (J.replay's page.strokes entries:
--- {a, rec, style, bb, points}), in drawing order, exactly as live ink
--- drew them.  region nil is the whole page; otherwise only that
--- physical rect is cleared and redrawn, and nothing outside it is
--- written.  page_n is the command's page number and does not change
--- the pixels.  cfg supplies W and H, the panel the controller clipped
--- its live spans to.
function Surface.render_page(bb, page_n, strokes, cfg, region)
    local W, H = cfg.W, cfg.H
    local cx0, cy0, cx1, cy1 = 0, 0, W - 1, H - 1
    if region then
        cx0, cy0 = region.x, region.y
        cx1, cy1 = cx0 + region.w - 1, cy0 + region.h - 1
        bb:paintRect(region.x, region.y, region.w, region.h, C_WHITE)
    else
        bb:fill(C_WHITE)
    end
    if cx1 < cx0 or cy1 < cy0 then return end
    set_target(bb)
    local function emit(y, x0, x1, dens)
        if y < cy0 or y > cy1 then return end
        if x0 < cx0 then x0 = cx0 end
        if x1 > cx1 then x1 = cx1 end
        if x0 <= x1 then P_row(y, x0, x1, dens) end
    end
    for i = 1, #strokes do
        local e = strokes[i]
        local style, points = e.style, e.points
        local draw = set_style(style.comp, style.pat)
        if draw and region then
            -- Brush.bbox bounds what render() can touch.  It is computed
            -- from the same points and style rather than read from the
            -- file's bb, and a stroke outside the region is skipped
            -- without rasterizing it.
            local b = entry_box(e)
            draw = b.x0 ~= nil and b.x0 <= cx1 and b.x1 >= cx0
                   and b.y0 <= cy1 and b.y1 >= cy0
        end
        if draw then Brush.render(style, points, W, H, emit) end
    end
    release()
end

--- paintTo's blit: the physical page onto target (Screen.bb, in its
--- rotation) at the paint offset x, y, so physical maps to physical.
--- rect, when given, is the logical {x, y, w, h} of the page to copy,
--- relative to x, y (the notebook blits the page only where its panel is
--- not); nil is the whole target.  The page's rotation and inverse flag
--- are matched to the target's for the C blitter and restored after.
--- When the flags differed, the C copy is inverted in place, as the
--- module header explains.
function Surface.blit_page(target, page, x, y, rect)
    x, y = x or 0, y or 0
    local rot, inv = page:getRotation(), page:getInverse()
    local tinv = target:getInverse()
    local tw, th = target:getWidth(), target:getHeight()
    local rx, ry, rw, rh = 0, 0, tw, th
    if rect then rx, ry, rw, rh = rect.x, rect.y, rect.w, rect.h end
    -- Without the C blitter (KOReader's dev_no_c_blitter) matching the
    -- flags gains nothing: blitFrom's per-pixel path honours both.  The
    -- in-place inversion would also take invertRect's Lua fallback,
    -- whose full-width BB8 and RGB24 loop raises an error on the 64-bit
    -- stride it uses as a loop limit.
    local flip = inv ~= tinv and Blitbuffer:getUseCBB()
    page:setRotation(target:getRotation())
    if flip then page:setInverse(tinv) end
    target:blitFrom(page, x + rx, y + ry, rx, ry, rw, rh)
    if flip then
        -- The rect blitFrom wrote, clipped as it clips.
        local bw, dx = Blitbuffer.checkBounds(rw, x + rx, rx, tw,
                                              page:getWidth())
        local bh, dy = Blitbuffer.checkBounds(rh, y + ry, ry, th,
                                              page:getHeight())
        if bw > 0 and bh > 0 then
            -- An xor ignores the flag; clearing it only picks the C path.
            target:setInverse(0)
            target:invertRect(dx, dy, bw, bh)
            target:setInverse(tinv)
        end
    end
    page:setRotation(rot)
    page:setInverse(inv)
end

--- The composed panel onto target: panel is a rotation-0 buffer in
--- target's LOGICAL orientation, whose top-left sits at target's logical
--- px, py; rect is the logical part of target to copy, inside the panel.
--- The glue composes the panel with target's type and inverse flag, so
--- this is the C blitter's straight copy: every pixel goes from what the
--- target held to the panel's pixel in one write.
function Surface.blit_panel(target, panel, px, py, rect)
    target:blitFrom(panel, rect.x, rect.y, rect.x - px, rect.y - py,
                    rect.w, rect.h)
end

--- bb as a PNG in physical orientation (rotation 0 whatever its flag),
--- gray for BB8 and RGB otherwise.  Returns true, or nil and a message.
function Surface.write_png(bb, path)
    -- lodepng loads through ffi/loadlib; without it, say so as a failed
    -- write rather than raise
    local ok_png, Png = pcall(require, "ffi/png")
    if not ok_png then return nil, tostring(Png) end
    local w, h = bb.w, bb.h
    local gray = bb:getType() == TYPE_BB8
    local n = gray and 1 or 3
    -- Blitbuffer's own writePNG dumps the logical orientation and drops
    -- the encoder's result; this dumps rotation 0 and returns it.
    local dump = Blitbuffer.new(w, h, gray and TYPE_BB8 or TYPE_BBRGB24,
                                nil, w * n, w)
    local rot = bb:getRotation()
    bb:setRotation(0)
    dump:blitFrom(bb)
    bb:setRotation(rot)
    local ok, err = Png.encodeToFile(path, ffi.cast(U8P, dump.data), w, h, n)
    dump:free()
    if ok then return true end
    -- lodepng's message comes back as a C string
    return nil, type(err) == "cdata" and ffi.string(err) or tostring(err)
end

return Surface
