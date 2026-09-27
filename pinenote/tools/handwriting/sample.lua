-- Host-only, read-only export of one labelled notebook page as one text line.
-- Replay is the notebook's own implementation, including undo/stroke erase.
local J = require("nb_journal")
local G = require("nb_geom")
local M = {}

local function xml(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
             :gsub('"', "&quot;"):gsub("'", "&apos;"))
end

function M.export(root, id, page_n, transcript, read)
    assert(type(page_n) == "number" and page_n == math.floor(page_n), "page must be an integer")
    transcript = transcript:gsub("\r?\n$", "")
    assert(#transcript > 0 and not transcript:find("[%z\1-\31]"), "transcript must be one nonempty text line")
    local nb, err = J.Store.new{ root = root, fs = { read = read } }:open(id)
    assert(nb, err)
    local meta = nb.meta
    local cfg = { W = meta.panel[1], H = meta.panel[2],
                  abs_x_max = meta.abs[1], abs_y_max = meta.abs[2] }
    assert(cfg.W > 1 and cfg.H > 1 and cfg.abs_x_max > 0 and cfg.abs_y_max > 0,
           "invalid notebook geometry")
    local path = nb.dir .. "/" .. J.page_name(page_n)
    local content, why = read(path)
    assert(content, why)
    assert(content:sub(-1) == "\n", "incomplete journal tail; export a closed notebook snapshot")
    local lines = {}
    for line in content:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local page = J.replay(lines, cfg)
    assert(page.bad_lines == 0 and page.ignored == 0, "damaged or ignored journal records")
    assert(#page.strokes > 0, "page has no active ink")
    local rotation = page.strokes[1].rec.rot
    assert(rotation >= 0 and rotation <= 3, "invalid stroke rotation")
    local samples, t0 = {}, nil
    for i, stroke in ipairs(page.strokes) do
        local r = stroke.rec
        assert(r.tool == "pen" and r.comp ~= "white",
               "area erase requires raster recognition; do not export hidden ink")
        assert(r.rot == rotation, "mixed writing orientations; use one orientation per labelled line")
        assert(r.gap == 0, "contact dropout in sample; collect a clean line")
        samples[i] = J.samples(r)
        for _, p in ipairs(samples[i]) do
            assert(p.rawx >= 0 and p.rawx <= cfg.abs_x_max and p.rawy >= 0 and p.rawy <= cfg.abs_y_max,
                   "sample outside notebook digitizer bounds")
            t0 = math.min(t0 or p.t, p.t)
        end
    end
    local out = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<ink xmlns="http://www.w3.org/2003/InkML">',
        '  <annotation type="truth">' .. xml(transcript) .. '</annotation>',
        '  <annotation type="source-notebook">' .. xml(id) .. '</annotation>',
        '  <annotation type="source-page">' .. tostring(page_n) .. '</annotation>',
        '  <annotation type="source-rotation">' .. rotation .. '</annotation>',
        '  <annotation type="coordinate-space">logical panel pixels; T is relative recorded realtime in ms; F and tilt are raw</annotation>',
        '  <traceFormat>',
        '    <channel name="X" type="decimal" units="dev"/>',
        '    <channel name="Y" type="decimal" units="dev"/>',
        '    <channel name="T" type="decimal" units="ms"/>',
        '    <channel name="F" type="integer"/>',
        '    <channel name="TX" type="integer"/>',
        '    <channel name="TY" type="integer"/>',
        '  </traceFormat>',
    }
    for i, stroke in ipairs(page.strokes) do
        local points = {}
        for k, p in ipairs(samples[i]) do
            local physical = stroke.points[k]
            local x, y = G.to_logical(rotation, cfg.W, cfg.H, physical.x, physical.y)
            points[#points + 1] = string.format("%.6f %.6f %.3f %.0f %.0f %.0f",
                x, y, (p.t - t0) / 1000, p.p, p.tx, p.ty)
        end
        out[#out + 1] = '  <trace xml:id="a' .. stroke.a .. '">' .. table.concat(points, ", ") .. '</trace>'
    end
    out[#out + 1] = '</ink>'
    return table.concat(out, "\n") .. "\n"
end

return M
