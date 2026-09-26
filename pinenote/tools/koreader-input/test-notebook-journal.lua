--[[--
Host harness for the notebook journal (nb_journal.lua): the page-file
format, replay, and the store, under the koreader-bin bundle's luajit.

  1. the restricted-JSON codec: golden lines pin the fixed key order;
     round-trip properties over generated records; the decoder accepts
     only canonical lines (every single-byte mutation it accepts
     re-encodes to itself, and no proper prefix of a line decodes);
  2. stroke_record, samples, points_px and style: the delta coding, the
     clamped realtime step, the digitizer edge (20966 -> 1871), the
     stored-hundredths style;
  3. replay semantics: undo, redo, stroke erase, redo clearing, and the
     records the strict stack ignores;
  4. J.apply equals replay after every record of a generated session, of
     a hostile one (reused ids, erases of erases, stray undo/redo), and
     for the built record as well as its decoded line;
  5. the store over an in-memory fs with fault injection (ENOSPC and
     EROFS on append and fsync, a torn write, EEXIST on mkdir) and a
     power-cut model (an unsynced append or directory entry is lost):
     check_data against mountinfo samples, create and id collisions,
     the rand() contract, the root's fsync retried after a failure,
     list, open and the format-version gate, UTC stamps against
     coreutils, negative page names, append/fsync rules (an unread page
     refuses appends), the torn tail at every byte offset of the last
     line, atomic prefs;
  6. replay time for a 2000-stroke x 300-sample page, reported on stderr
     and not gated (stdout stays deterministic).

NOT covered here: the glue's real fs (ffi open/write/fsync/rename and
/proc/self/mountinfo); that is main.lua's, exercised on the device.

Usage: luajit test-notebook-journal.lua /path/to/bundle/lib/koreader \
           /path/to/repo/.../plugins/notebook.koplugin
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")
local _ = koreader_dir  -- the journal needs no KOReader module

package.path = plugin_dir .. "/?.lua;" .. package.path

local J = require("nb_journal")
local Config = require("nb_config")

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label,
                        msg or ""))
    if not ok then fail = fail + 1 end
end

local function eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function list(t)
    local out = {}
    for i, v in ipairs(t) do out[i] = tostring(v) end
    return "{" .. table.concat(out, ",") .. "}"
end

-- Park-Miller: products stay below 2^53, so doubles hold it exactly.
local seed = 20260926
local function rnd(n)
    seed = seed * 16807 % 2147483647
    return seed % n
end

local cfg = {}
for k, v in pairs(Config) do cfg[k] = v end

local T0 = 1790000000123456  -- a realtime microsecond stamp, 16 digits

local PEN = { brush = "ballpoint", size = "M", tool = "pen", rmin = 1.5,
              rmax = 3.25, gamma = 1.6, plo = 100, phi = 4095,
              comp = "black", pat = "solid" }
local ERASER = { brush = "ballpoint", size = "M", tool = "eraser",
                 rmin = 12, rmax = 24, gamma = 1, plo = 180, phi = 880,
                 comp = "white", pat = "solid" }

local function pts(n, x0, y0)
    local out = {}
    for i = 1, n do
        out[i] = { t = T0 + (i - 1) * 2770, rawx = x0 + i * 10,
                   rawy = y0 - i * 5, p = 500 + i, tx = 10, ty = -5 }
    end
    return out
end

local function S(a, style, n)
    return J.encode(J.stroke_record(a, style or PEN, 1, T0, pts(n or 3, 1000 + a, 2000),
                                    false, { 0, 0, 10, 10 }))
end
local function X(a, ids) return J.encode{ k = "x", a = a, ids = ids } end
local function U(a) return J.encode{ k = "u", a = a } end
local function R(a) return J.encode{ k = "r", a = a } end

------------------------------------------------------------------------
-- 1. The codec.
------------------------------------------------------------------------

local rec_s = J.stroke_record(3, PEN, 1, T0, {
    { t = T0, rawx = 1000, rawy = 2000, p = 500, tx = 10, ty = -5 },
    { t = T0 + 2770, rawx = 1010, rawy = 1995, p = 620, tx = 11, ty = -5 },
    -- realtime stepped back 100 us: the delta clamps to 0
    { t = T0 + 2670, rawx = 1020, rawy = 1990, p = 600, tx = 11, ty = -4 },
}, false, { 10.2, 20.7, 30.1, 40.9 })

local golden = {
    { rec_s, '{"k":"s","a":3,"tool":"pen","brush":"ballpoint","size":"M",'
             .. '"st":[150,325,160,100,4095,0,0],"comp":"black","pat":"solid",'
             .. '"rot":1,"t0":1790000000123456,"gap":0,"bb":[10,20,31,41],'
             .. '"d":[0,1000,2000,500,10,-5,2770,10,-5,120,1,0,0,10,-5,-20,0,1]}' },
    { { k = "x", a = 4, ids = { 1, 3 } }, '{"k":"x","a":4,"ids":[1,3]}' },
    { { k = "u", a = 4 }, '{"k":"u","a":4}' },
    { { k = "r", a = 4 }, '{"k":"r","a":4}' },
}
for _, g in ipairs(golden) do
    local line = J.encode(g[1])
    report(line == g[2], "golden " .. g[1].k .. " record: fixed key order",
           line)
    report(eq(J.decode(g[2]), g[1]), "golden " .. g[1].k
           .. " record decodes to the record")
end

-- Generated records: decode(encode(r)) == r, and encode(decode(line)) is
-- the line's own bytes.
local CHARS = "ABCXYZabcxyz0189_.-"
local function rstr()
    local n, out = rnd(10), {}
    for i = 1, n do
        local c = rnd(#CHARS) + 1
        out[i] = CHARS:sub(c, c)
    end
    return table.concat(out)
end
local EDGE = { 0, 1, -1, 9, 10, -10, 4095, J._codec.MAXI, -J._codec.MAXI }
local function rint()
    local c = rnd(4)
    if c == 0 then return EDGE[rnd(#EDGE) + 1] end
    if c == 1 then return rnd(100000) - 50000 end
    if c == 2 then return (rnd(2) == 0 and 1 or -1) * (rnd(2^22) * 2^31 + rnd(2^31)) end
    return rnd(30)
end
local function rpos() return rnd(2^31 - 2) + 1 end
local function rarr(n)
    local out = {}
    for i = 1, n do out[i] = rint() end
    return out
end
local function rrec()
    local kind = ({ "s", "x", "u", "r" })[rnd(4) + 1]
    if kind == "s" then
        return { k = "s", a = rpos(), tool = rnd(2) == 0 and "pen" or "eraser",
                 brush = rstr(), size = rstr(), st = rarr(7), comp = rstr(),
                 pat = rstr(), rot = rint(), t0 = rint(), gap = rnd(2),
                 bb = rarr(4), d = rarr(6 * (rnd(8) + 1)) }
    elseif kind == "x" then
        local ids = {}
        for i = 1, rnd(5) do ids[i] = rpos() end
        return { k = "x", a = rpos(), ids = ids }
    end
    return { k = kind, a = rpos() }
end
do
    local bad, n = 0, 600
    for _ = 1, n do
        local r = rrec()
        local line = J.encode(r)
        local back = J.decode(line)
        if not (back and eq(back, r) and J.encode(back) == line) then
            bad = bad + 1
        end
    end
    report(bad == 0, "round trip: decode(encode(r)) == r and re-encoding"
           .. " gives the same bytes", n .. " generated records, " .. bad .. " bad")
end

-- Canonical only: mutate each golden line at every byte (substitute,
-- delete, insert); whatever the decoder accepts must re-encode to exactly
-- the mutant, so no second spelling of a record exists.
do
    local ALPHA = { "0", "1", "9", "-", ",", ":", '"', "{", "}", "[", "]",
                    " ", "a", "k", ".", "e", "\n", "\0" }
    local tried, accepted, bad = 0, 0, 0
    local function try(m)
        tried = tried + 1
        local r = J.decode(m)
        if r then
            accepted = accepted + 1
            if J.encode(r) ~= m then bad = bad + 1 end
        end
    end
    for _, g in ipairs(golden) do
        local s = g[2]
        for i = 1, #s do
            local pre, post = s:sub(1, i - 1), s:sub(i + 1)
            try(pre .. post)
            for _, c in ipairs(ALPHA) do
                try(pre .. c .. post)
                try(pre .. c .. s:sub(i))
            end
        end
    end
    report(bad == 0, "every accepted mutation re-encodes to itself (one"
           .. " spelling per record)", string.format("%d mutants, %d accepted,"
           .. " %d non-canonical", tried, accepted, bad))
end

do
    local bad = 0
    for _, g in ipairs(golden) do
        for i = 0, #g[2] - 1 do
            if J.decode(g[2]:sub(1, i)) then bad = bad + 1 end
        end
    end
    report(bad == 0, "no proper prefix of a line decodes (a torn line is"
           .. " never a record)", bad .. " decoded")
end

local s_head = '{"k":"s","a":1,"tool":"pen","brush":"b","size":"M",'
    .. '"st":[1,2,3,4,5,6,7],"comp":"black","pat":"solid","rot":0,'
    .. '"t0":0,"gap":0,"bb":[0,0,1,1],"d":'
local rejects = {
    { "whitespace", '{"k":"u", "a":1}' },
    { "leading zero", '{"k":"u","a":01}' },
    { "negative zero", '{"k":"x","a":2,"ids":[-0]}' },
    { "fraction", '{"k":"u","a":1.0}' },
    { "exponent", '{"k":"u","a":1e3}' },
    { "plus sign", '{"k":"u","a":+1}' },
    { "2^53", '{"k":"u","a":9007199254740992}' },
    { "17 digits", '{"k":"u","a":12345678901234567}' },
    { "2^53 in an array", '{"k":"x","a":2,"ids":[1,9007199254740992]}' },
    { "-2^53 in samples", s_head .. "[0,0,0,0,0,-9007199254740992]}" },
    { "leading zero in an array", '{"k":"x","a":2,"ids":[1,02]}' },
    { "unknown key", '{"k":"u","a":1,"z":1}' },
    { "missing key", '{"k":"x","a":1}' },
    { "key order", '{"a":1,"k":"u"}' },
    { "duplicate key", '{"k":"u","a":1,"a":1}' },
    { "escape in string", s_head:gsub('"b"', '"b\\"x"') .. "[0,0,0,0,0,0]}" },
    { "space in string", s_head:gsub('"b"', '"b x"') .. "[0,0,0,0,0,0]}" },
    { "trailing byte", '{"k":"u","a":1}x' },
    { "trailing newline", '{"k":"u","a":1}\n' },
    { "unknown kind", '{"k":"q","a":1}' },
    { "empty line", "" },
    { "boolean for integer", '{"k":"u","a":true}' },
    { "string for integer", '{"k":"u","a":"1"}' },
    { "nested array", '{"k":"x","a":2,"ids":[[1]]}' },
    { "trailing comma", '{"k":"x","a":2,"ids":[1,]}' },
    { "leading comma", '{"k":"x","a":2,"ids":[,1]}' },
    { "empty element", '{"k":"x","a":2,"ids":[1,,2]}' },
    { "action 0", '{"k":"u","a":0}' },
    { "negative action", '{"k":"r","a":-4}' },
    { "erased id 0", '{"k":"x","a":2,"ids":[0]}' },
    { "partial sample", s_head .. "[0,0,0,0,0]}" },
    { "no samples", s_head .. "[]}" },
    { "st of 6", (s_head:gsub(",7%]", "]")) .. "[0,0,0,0,0,0]}" },
    { "gap 2", (s_head:gsub('"gap":0', '"gap":2')) .. "[0,0,0,0,0,0]}" },
    { "tool brush", (s_head:gsub('"pen"', '"brush"')) .. "[0,0,0,0,0,0]}" },
    { "NUL byte", '{"k":"u","a":1\0}' },
    { "a second closing brace", '{"k":"u","a":1}}' },
    { "no closing brace", '{"k":"u","a":1' },
    { "no closing bracket", '{"k":"x","a":2,"ids":[1}' },
    { "a 400-digit integer", '{"k":"u","a":' .. ("9"):rep(400) .. "}" },
    { "a bare minus", '{"k":"u","a":-}' },
    { "a leading space", ' {"k":"u","a":1}' },
    { "a two-letter kind", '{"k":"uu","a":1}' },
    { "a carriage return", '{"k":"u","a":1}\r' },
}
for _, c in ipairs(rejects) do
    local r, err = J.decode(c[2])
    report(r == nil and type(err) == "string", "decode rejects: " .. c[1],
           tostring(err))
end
local accepts = {
    { "largest integer", '{"k":"u","a":9007199254740991}' },
    { "empty erase list", '{"k":"x","a":2,"ids":[]}' },
    { "negative samples", s_head .. "[0,-1,-20,0,-9000,9000]}" },
}
for _, c in ipairs(accepts) do
    local r = J.decode(c[2])
    report(r ~= nil and J.encode(r) == c[2], "decode accepts: " .. c[1])
end

local raises = {
    { "fractional action", { k = "u", a = 1.5 } },
    { "NaN", { k = "u", a = 0 / 0 } },
    { "infinity", { k = "u", a = math.huge } },
    { "past 2^53", { k = "u", a = 2^53 } },
    { "space in a string", { k = "s", a = 1, tool = "pen", brush = "a b",
      size = "M", st = { 1, 2, 3, 4, 5, 6, 7 }, comp = "black", pat = "solid",
      rot = 0, t0 = 0, gap = 0, bb = { 0, 0, 1, 1 }, d = { 0, 0, 0, 0, 0, 0 } } },
    { "missing field", { k = "x", a = 1 } },
    { "unknown field", { k = "u", a = 1, z = 1 } },
    { "array with a hole", { k = "x", a = 2, ids = { 1, nil, 3 } } },
    { "array with a named field", { k = "x", a = 2, ids = { 1, n = 2 } } },
    { "unknown kind", { k = "q", a = 1 } },
    { "action 0 (a line decode would refuse)", { k = "u", a = 0 } },
    { "empty d", J.decode(s_head .. "[0,0,0,0,0,0]}") and (function()
        local r = J.decode(s_head .. "[0,0,0,0,0,0]}")
        r.d = {}
        return r
    end)() },
}
for _, c in ipairs(raises) do
    local ok, err = pcall(J.encode, c[2])
    report(not ok and type(err) == "string" and err:find("^nb_journal: ") ~= nil,
           "encode raises: " .. c[1], tostring(err))
end

-- The codec's other two value types: booleans (no record uses one yet)
-- and prefs.json's string-to-integer map.
do
    local C = J._codec
    local sch = C.schema{ { "flag", "bool" }, { "n", "int", true } }
    report(C.encode_obj({ flag = true }, sch) == '{"flag":true}'
           and C.encode_obj({ flag = false, n = 3 }, sch) == '{"flag":false,"n":3}',
           "booleans encode, an absent optional field is omitted")
    report(eq(C.decode_obj('{"flag":false,"n":3}', sch), { flag = false, n = 3 })
           and C.decode_obj('{"flag":tru}', sch) == nil
           and C.decode_obj('{"flag":1}', sch) == nil
           and C.decode_obj('{"n":3}', sch) == nil,
           "booleans decode; a truncated or numeric boolean, or a missing"
           .. " required field, is refused")
    local m = { last_page = { ["b-2"] = 3, ["a-1"] = -2 } }
    local line = C.encode_obj(m, C.PREFS)
    report(line == '{"last_page":{"a-1":-2,"b-2":3}}'
           and eq(C.decode_obj(line, C.PREFS), m),
           "a map encodes keys sorted and round-trips", line)
    report(C.decode_obj('{"last_page":{"b":1,"a":2}}', C.PREFS) == nil
           and C.decode_obj('{"last_page":{"a":1,"a":2}}', C.PREFS) == nil
           and eq(C.decode_obj('{"last_page":{}}', C.PREFS), { last_page = {} })
           and eq(C.decode_obj("{}", C.PREFS), {}),
           "a map refuses unsorted and duplicate keys; empty map and empty"
           .. " object decode")
end

------------------------------------------------------------------------
-- 2. Samples, px points and styles.
------------------------------------------------------------------------

do
    local s = J.samples(rec_s)
    report(eq(s, {
        { t = T0, rawx = 1000, rawy = 2000, p = 500, tx = 10, ty = -5 },
        { t = T0 + 2770, rawx = 1010, rawy = 1995, p = 620, tx = 11, ty = -5 },
        { t = T0 + 2770, rawx = 1020, rawy = 1990, p = 600, tx = 11, ty = -4 },
    }), "samples() undoes the delta coding; the backward step reads as 0 us")

    local src = pts(40, 3000, 9000)
    local r = J.decode(J.encode(J.stroke_record(1, PEN, 0, T0 - 5, src, true,
                                                { 0, 0, 1, 1 })))
    local back = J.samples(r)
    local same = #back == #src
    for i = 1, #src do
        for _, k in ipairs{ "t", "rawx", "rawy", "p", "tx", "ty" } do
            if back[i][k] ~= src[i][k] then same = false end
        end
    end
    report(same and r.d[1] == 5 and r.gap == 1,
           "stroke_record -> encode -> decode -> samples returns every sample;"
           .. " the first t is relative to t0", "d[1]=" .. r.d[1])

    local edge = J.stroke_record(1, PEN, 0, T0, {
        { t = T0, rawx = 0, rawy = 0, p = 0 },
        { t = T0, rawx = 20966, rawy = 15725, p = 4095 },
        { t = T0, rawx = 21000, rawy = -7, p = 4095 },
    }, nil, { 0, 0, 1, 1 })
    local px = J.points_px(edge, cfg)
    report(px[1].x == 0 and px[1].y == 0 and px[2].x == 1871
           and px[2].y == 1403 and px[3].x == 1871 and px[3].y == 0
           and px[2].p == 4095 and edge.d[5] == 0 and edge.gap == 0,
           "points_px: 0 -> 0, 20966 -> 1871, 15725 -> 1403, out of range"
           .. " clamps; absent tilt stores 0",
           string.format("(%g,%g) (%g,%g) (%g,%g)", px[1].x, px[1].y,
                         px[2].x, px[2].y, px[3].x, px[3].y))

    local st = J.style(rec_s)
    report(st.rmin == 1.5 and st.rmax == 3.25 and st.gamma == 1.6
           and st.plo == 100 and st.phi == 4095 and st.comp == "black"
           and st.pat == "solid" and st.tool == "pen" and st.dlo == 0,
           "style(rec) gives the stored hundredths back as the brush style")
    local pencil = J.style(J.stroke_record(1, { brush = "pencil", size = "S",
        tool = "pen", rmin = 0.8333, rmax = 2, gamma = 1.25, plo = 100,
        phi = 4095, comp = "darken", pat = "bayer4", dlo = 0.2, dhi = 0.95 },
        0, T0, pts(1, 0, 0), false, { 0, 0, 1, 1 }))
    report(pencil.rmin == 0.83 and pencil.dlo == 0.2 and pencil.dhi == 0.95
           and pencil.pat == "bayer4",
           "a pattern brush keeps its density window; radii quantize to 0.01 px",
           "rmin=" .. pencil.rmin)
    local g1 = J.stroke_record(1, PEN, 0, T0, pts(1, 0, 0), 1, { -0.5, 3, 7.01, 8 })
    local g0 = J.stroke_record(1, PEN, 0, T0, pts(1, 0, 0), 0, { 0, 0, 1, 1 })
    report(g1.gap == 1 and g0.gap == 0 and eq(g1.bb, { -1, 3, 8, 8 }),
           "gap accepts true/1 and false/0/nil; bb rounds outward",
           list(g1.bb))
    report(not pcall(J.stroke_record, 1, PEN, 0, T0, {}, false, { 0, 0, 1, 1 }),
           "stroke_record refuses a stroke with no samples")
end

------------------------------------------------------------------------
-- 3. Replay semantics.
------------------------------------------------------------------------

local function visible(page)
    local out = {}
    for i, e in ipairs(page.strokes) do out[i] = e.a end
    return list(out)
end

local function state(page)
    return string.format("vis=%s undo=%s redo=%s next=%d bad=%d ignored=%d",
                         visible(page), tostring(page.undo_target),
                         tostring(page.redo_target), page.next_action,
                         page.bad_lines, page.ignored)
end

local scripts = {
    { "three strokes", { S(1), S(2), S(3) },
      "vis={1,2,3} undo=3 redo=nil next=4 bad=0 ignored=0" },
    { "two undos push the redo stack",
      { S(1), S(2), S(3), U(3), U(2) },
      "vis={1} undo=1 redo=2 next=4 bad=0 ignored=0" },
    { "redo pops the top",
      { S(1), S(2), S(3), U(3), U(2), R(2) },
      "vis={1,2} undo=2 redo=3 next=4 bad=0 ignored=0" },
    { "new ink clears redo; the cleared action stays dead",
      { S(1), S(2), S(3), U(3), S(4), R(3) },
      "vis={1,2,4} undo=4 redo=nil next=5 bad=0 ignored=1" },
    { "stroke erase hides, its undo restores, its redo hides again",
      { S(1), S(2), X(3, { 1 }), U(3) },
      "vis={1,2} undo=2 redo=3 next=4 bad=0 ignored=0" },
    { "redo of an erase",
      { S(1), S(2), X(3, { 1 }), U(3), R(3) },
      "vis={2} undo=3 redo=nil next=4 bad=0 ignored=0" },
    { "undo past an erase, then redo both",
      { S(1), X(2, { 1 }), U(2), U(1), R(1), R(2) },
      "vis={} undo=2 redo=nil next=3 bad=0 ignored=0" },
    { "undo past an erase: the stroke is gone with its own undo",
      { S(1), X(2, { 1 }), U(2), U(1) },
      "vis={} undo=nil redo=1 next=3 bad=0 ignored=0" },
    { "two erases of one stroke: undoing one keeps it hidden",
      { S(1), X(2, { 1 }), X(3, { 1 }), U(3) },
      "vis={} undo=2 redo=3 next=4 bad=0 ignored=0" },
    { "undoing both erases shows it",
      { S(1), X(2, { 1 }), X(3, { 1 }), U(3), U(2) },
      "vis={1} undo=1 redo=2 next=4 bad=0 ignored=0" },
    { "out-of-order undo and redo are ignored",
      { S(1), S(2), U(1), R(2), U(2), R(1) },
      "vis={1} undo=1 redo=2 next=3 bad=0 ignored=3" },
    { "a repeated action id is drawn once",
      { S(1), S(1) }, "vis={1} undo=1 redo=nil next=2 bad=0 ignored=1" },
    { "an erase ignores unknown and non-stroke ids; they still count for"
      .. " the next id",
      { S(1), X(2, { 7, 1 }), X(3, { 2 }), U(3), U(2) },
      "vis={1} undo=1 redo=2 next=8 bad=0 ignored=0" },
    { "an erase cannot hide a stroke written after it",
      { X(1, { 2 }), S(2) },
      "vis={2} undo=2 redo=nil next=3 bad=0 ignored=0" },
    { "bad lines are skipped and counted; a legible id is reserved",
      { S(1), "garbage", '{"k":"s","a":5,"tool":"pen"', S(2) },
      "vis={1,2} undo=2 redo=nil next=6 bad=2 ignored=0" },
    { "a non-string line is a bad line", { S(1), 42 },
      "vis={1} undo=1 redo=nil next=2 bad=1 ignored=0" },
    { "eraser strokes draw in file order",
      { S(1), S(2, ERASER), S(3) },
      "vis={1,2,3} undo=3 redo=nil next=4 bad=0 ignored=0" },
    { "undo everything; one more undo is ignored",
      { S(1), U(1), U(1) },
      "vis={} undo=nil redo=1 next=2 bad=0 ignored=1" },
    { "a blank page", {}, "vis={} undo=nil redo=nil next=1 bad=0 ignored=0" },
}
for _, sc in ipairs(scripts) do
    local got = state(J.replay(sc[2], cfg))
    report(got == sc[3], "replay: " .. sc[1], got)
end
do
    local page = J.replay({ S(1, PEN, 4), S(2, ERASER, 2) }, cfg)
    local e1, e2 = page.strokes[1], page.strokes[2]
    report(#e1.points == 4 and #e2.points == 2 and e2.style.comp == "white"
           and e1.style.rmax == 3.25 and e1.rec.a == 1 and e1.bb == e1.rec.bb,
           "a stroke entry carries its action, record, style, bb and px points")
    report(J.replay({ S(1) }).strokes[1].points[1].x
           == J.replay({ S(1) }, cfg).strokes[1].points[1].x,
           "replay without cfg maps px with nb_config")
end

------------------------------------------------------------------------
-- 4. J.apply equals replay, record by record.
------------------------------------------------------------------------

local function dump(page)
    local out = { state(page) }
    for _, e in ipairs(page.strokes) do
        local p = e.points[#e.points]
        out[#out + 1] = string.format("%d:%d:%.3f,%.3f:%s", e.a, #e.points,
                                      p.x, p.y, e.style.tool)
    end
    return table.concat(out, " ")
end

do
    -- A session the way the controller writes it, with a few records a
    -- damaged or hand-edited file might hold mixed in.
    local lines, page = {}, J.replay({}, cfg)
    local mismatch, first = 0, nil
    local kinds = { s = 0, x = 0, u = 0, r = 0 }
    for step = 1, 300 do
        local c, line = rnd(20), nil
        if c < 8 then
            line = S(page.next_action, rnd(4) == 0 and ERASER or PEN, rnd(5) + 1)
        elseif c < 11 and #page.strokes > 0 then
            local ids = {}
            for i = 1, rnd(3) + 1 do
                ids[i] = page.strokes[rnd(#page.strokes) + 1].a
            end
            line = X(page.next_action, ids)
        elseif c < 15 and page.undo_target then
            line = U(page.undo_target)
        elseif c < 18 and page.redo_target then
            line = R(page.redo_target)
        elseif c == 18 then
            line = U(rnd(page.next_action) + 1)
        else
            line = R(rnd(page.next_action) + 1)
        end
        local rec = J.decode(line)
        kinds[rec.k] = kinds[rec.k] + 1
        lines[#lines + 1] = line
        J.apply(page, rec)
        local want = dump(J.replay(lines, cfg))
        if dump(page) ~= want then
            mismatch = mismatch + 1
            first = first or step
        end
    end
    report(mismatch == 0, "J.apply equals replay after each of 300 records",
           string.format("s=%d x=%d u=%d r=%d ignored=%d visible=%d first=%s",
                         kinds.s, kinds.x, kinds.u, kinds.r, page.ignored,
                         #page.strokes, tostring(first)))
end

do
    -- The same equality over records no controller writes: reused and
    -- duplicated ids, erases naming erases, themselves, future ids and dead
    -- strokes, and undo/redo aimed at random ids.
    local lines, page = {}, J.replay({}, cfg)
    local mismatch, first = 0, nil
    for step = 1, 400 do
        local c, line = rnd(12), nil
        local any = rnd(page.next_action + 2) + 1
        if c < 3 then
            line = S(page.next_action, PEN, rnd(3) + 1)
        elseif c == 3 then
            line = S(any, PEN, 1)
        elseif c < 6 then
            local ids = {}
            for i = 1, rnd(4) do ids[i] = rnd(page.next_action + 3) + 1 end
            local a = rnd(3) == 0 and any or page.next_action
            if rnd(4) == 0 then ids[#ids + 1] = a end
            line = X(a, ids)
        elseif c < 8 then
            line = U(rnd(2) == 0 and page.undo_target or any)
        elseif c < 10 then
            line = R(rnd(2) == 0 and page.redo_target or any)
        else
            line = U(page.undo_target or any)
        end
        lines[#lines + 1] = line
        J.apply(page, J.decode(line))
        if dump(page) ~= dump(J.replay(lines, cfg)) then
            mismatch = mismatch + 1
            first = first or step
        end
    end
    report(mismatch == 0, "J.apply equals replay after each of 400 hostile"
           .. " records", string.format("ignored=%d visible=%d next=%d first=%s",
                                        page.ignored, #page.strokes,
                                        page.next_action, tostring(first)))
end

do
    -- The controller may apply the record it built rather than the one a
    -- reread decodes; the page must come out the same.
    local function built(a, style, gap)
        return J.stroke_record(a, style, 1, T0 + 0.4, pts(4, 100 * a, 7000),
                               gap, { 1.5, 2.5, 30.2, 40.7 })
    end
    local p1, p2 = J.replay({}, cfg), J.replay({}, cfg)
    local recs = { built(1, PEN, false), built(2, PEN, true),
                   { k = "x", a = 3, ids = { 1 } }, { k = "u", a = 3 },
                   built(4, ERASER, 1) }
    for _, rec in ipairs(recs) do
        J.apply(p1, rec)
        J.apply(p2, J.decode(J.encode(rec)))
    end
    report(dump(p1) == dump(p2), "J.apply of the built record equals J.apply"
           .. " of its decoded line", dump(p1))
end

------------------------------------------------------------------------
-- 5. The store, over an in-memory fs.
------------------------------------------------------------------------

-- The fs interface in memory.  Each node has data (what reads see),
-- synced (what an fsync last made durable) and durable (whether its
-- directory entry survives a power cut: set by fsync_dir of the parent).
-- crash() is the power cut.  fault(op, err, {path=, times=, torn=})
-- makes an op fail; torn=k makes an append write k bytes first.
local function MemFS()
    local nodes = { ["/"] = { dir = true, durable = true } }
    local faults = {}
    local fs = { calls = {}, log = {} }

    local function parent(p) return p:match("^(.*)/[^/]*$") or "/" end
    local function dirp(p)
        local d = parent(p)
        if d == "" then d = "/" end
        return nodes[d] and nodes[d].dir
    end
    local function hit(op, path)
        fs.calls[op] = (fs.calls[op] or 0) + 1
        fs.log[#fs.log + 1] = op .. " " .. path
        for i, f in ipairs(faults) do
            if f.op == op and (f.path == nil or f.path == path) then
                if f.times then
                    f.times = f.times - 1
                    if f.times == 0 then table.remove(faults, i) end
                end
                return f
            end
        end
    end

    function fs.mkdir_excl(path)
        local f = hit("mkdir_excl", path)
        if f then return nil, f.err end
        if nodes[path] then return nil, "EEXIST" end
        if not dirp(path) then return nil, "ENOENT" end
        nodes[path] = { dir = true, durable = false }
        return true
    end
    function fs.listdir(path)
        local f = hit("listdir", path)
        if f then return nil, f.err end
        if not (nodes[path] and nodes[path].dir) then return nil, "ENOENT" end
        local names = {}
        for p in pairs(nodes) do
            if p ~= "/" and parent(p) == path then
                names[#names + 1] = p:match("[^/]*$")
            end
        end
        -- reverse order, so the store's own sorting is what the test sees
        table.sort(names, function(a, b) return a > b end)
        return names
    end
    function fs.read(path)
        local f = hit("read", path)
        if f then return nil, f.err end
        local n = nodes[path]
        if not n then return nil, "ENOENT" end
        if n.dir then return nil, "EISDIR" end
        return n.data
    end
    function fs.append(path, s)
        local f = hit("append", path)
        if f and not f.torn then return nil, f.err end
        if not dirp(path) then return nil, "ENOENT" end
        local n = nodes[path]
        if not n then
            n = { data = "", durable = false }
            nodes[path] = n
        end
        if f then
            n.data = n.data .. s:sub(1, f.torn)
            return nil, f.err
        end
        n.data = n.data .. s
        return true
    end
    function fs.truncate(path, len)
        local f = hit("truncate", path)
        if f then return nil, f.err end
        local n = nodes[path]
        if not n or n.dir then return nil, "ENOENT" end
        n.data = n.data:sub(1, len)
        return true
    end
    function fs.fsync(path)
        local f = hit("fsync", path)
        if f then return nil, f.err end
        local n = nodes[path]
        if not n or n.dir then return nil, "ENOENT" end
        n.synced = n.data
        return true
    end
    function fs.fsync_dir(path)
        local f = hit("fsync_dir", path)
        if f then return nil, f.err end
        if not (nodes[path] and nodes[path].dir) then return nil, "ENOENT" end
        for p, n in pairs(nodes) do
            if p ~= "/" and parent(p) == path then n.durable = true end
        end
        return true
    end
    -- tmp, fsync, rename, fsync dir: all or nothing, and durable
    function fs.write_atomic(path, s)
        local f = hit("write_atomic", path)
        if f then return nil, f.err end
        if not dirp(path) then return nil, "ENOENT" end
        nodes[path] = { data = s, synced = s, durable = true }
        return true
    end
    function fs.exists(path)
        fs.calls.exists = (fs.calls.exists or 0) + 1
        return nodes[path] ~= nil
    end

    -- test controls
    function fs.fault(op, err, o)
        o = o or {}
        faults[#faults + 1] = { op = op, err = err, path = o.path,
                                times = o.times, torn = o.torn }
    end
    function fs.clear_faults() faults = {} end
    function fs.reset_log()
        fs.calls, fs.log = {}, {}
    end
    function fs.put(path, data)
        local d = parent(path)
        if d ~= "" and not nodes[d] then fs.mkdirs(d) end
        nodes[path] = { data = data, synced = data, durable = true }
    end
    function fs.mkdirs(path)
        if path == "" or path == "/" or nodes[path] then return end
        fs.mkdirs(parent(path))
        nodes[path] = { dir = true, durable = true }
    end
    function fs.get(path) return nodes[path] and nodes[path].data end
    function fs.crash()
        local paths = {}
        for p in pairs(nodes) do paths[#paths + 1] = p end
        table.sort(paths, function(a, b) return #a < #b end)
        for _, p in ipairs(paths) do
            local n, d = nodes[p], parent(p)
            if d == "" then d = "/" end
            if p ~= "/" and (not n.durable or not nodes[d]) then
                nodes[p] = nil
            elseif not n.dir then
                n.data = n.synced or ""
            end
        end
    end
    return fs
end

local ROOT = "/data/notebooks"
local NOW = 1790000000
local STAMP = "20260921T141320Z"

local function seq(values)
    local i = 0
    return function()
        i = i + 1
        return values[i] or values[#values]
    end
end

local function new_store(fs, rand)
    return J.Store.new{ fs = fs, root = ROOT, cfg = cfg,
                        rand = rand or seq{ 0xabcdef } }
end

local function data_fs()
    local fs = MemFS()
    fs.mkdirs("/data")
    return fs
end

-- 5a. check_data against mountinfo text.
do
    local store = new_store(data_fs())
    local ROOTM = "22 1 179:6 / / rw,relatime shared:1 - ext4 /dev/mmcblk0p6 rw"
    local PROC = "23 22 0:21 / /proc rw,nosuid,nodev,noexec,relatime shared:2"
                 .. " - proc proc rw"
    local DATA = "31 22 179:7 / /data rw,relatime shared:13 - ext4"
                 .. " /dev/mmcblk0p7 rw"
    local function mi(...) return table.concat({ ... }, "\n") .. "\n" end
    local cases = {
        { "the real data partition", mi(ROOTM, PROC, DATA), true },
        { "no optional fields",
          mi(ROOTM, "31 22 179:7 / /data rw,relatime - ext4 /dev/mmcblk0p7 rw"),
          true },
        { "two optional fields",
          mi(ROOTM, "31 22 179:7 / /data rw shared:13 master:4 - ext4 /dev/x rw"),
          true },
        { "the placeholder (p7 did not mount)", mi(ROOTM, PROC), false,
          "/data/notebooks is on the OS root filesystem, not the data partition" },
        { "a bind of the OS root at /data",
          mi(ROOTM, "31 22 179:6 /data /data rw,relatime - ext4 /dev/mmcblk0p6 rw"),
          false,
          "/data/notebooks is on the OS root filesystem, not the data partition" },
        { "mounted read-only",
          mi(ROOTM, "31 22 179:7 / /data ro,relatime - ext4 /dev/mmcblk0p7 ro"),
          false, "/data is mounted read-only" },
        { "errors=remount-ro tripped (superblock ro, mount rw)",
          mi(ROOTM, "31 22 179:7 / /data rw,relatime - ext4 /dev/mmcblk0p7"
                    .. " ro,errors=remount-ro"),
          false, "/data is mounted read-only" },
        { "not ext4",
          mi(ROOTM, "31 22 0:40 / /data rw,relatime - tmpfs tmpfs rw"),
          false, "/data is tmpfs, not ext4" },
        { "tmpfs stacked over the data partition", mi(ROOTM, DATA,
          "40 31 0:40 / /data rw,relatime - tmpfs tmpfs rw"),
          false, "/data is tmpfs, not ext4" },
        { "the data partition stacked over tmpfs", mi(ROOTM,
          "40 22 0:40 / /data rw,relatime - tmpfs tmpfs rw",
          "41 40 179:7 / /data rw,relatime - ext4 /dev/mmcblk0p7 rw"), true },
        { "lookalike mount points do not cover", mi(ROOTM,
          "31 22 179:7 / /data2 rw - ext4 /dev/mmcblk0p7 rw",
          "32 22 179:8 / /dat rw - ext4 /dev/mmcblk0p8 rw",
          "33 22 179:9 / /data\\040old rw - ext4 /dev/mmcblk0p9 rw"), false,
          "/data/notebooks is on the OS root filesystem, not the data partition" },
        { "a mount at the root itself is the one checked", mi(ROOTM, DATA,
          "50 31 0:41 / /data/notebooks rw - tmpfs tmpfs rw"),
          false, "/data/notebooks is tmpfs, not ext4" },
        { "a bind of the OS root stacked over the data partition", mi(ROOTM,
          DATA, "51 31 179:6 /data /data rw,relatime - ext4 /dev/mmcblk0p6 rw"),
          false,
          "/data/notebooks is on the OS root filesystem, not the data partition" },
        { "the root line listed after /data", mi(DATA, PROC, ROOTM), true },
        { "malformed lines are skipped", mi("garbage", "1 2 3", ROOTM,
          "31 22 179:7 / /data rw - ext4", DATA), true },
        { "no mounts at all", "", false, "no mount covers /data/notebooks" },
        { "no mountinfo text", nil, false, "no mountinfo" },
    }
    for _, c in ipairs(cases) do
        local ok, why = store:check_data(c[2])
        report(ok == c[3] and (c[3] or why == c[4]), "check_data: " .. c[1],
               ok and "ok" or tostring(why))
    end
end

-- 5b. The probe.
do
    local fs = data_fs()
    local store = new_store(fs)
    local ok = store:probe()
    report(ok and table.concat(fs.log, "; ")
                  == "mkdir_excl /data/notebooks; fsync_dir /data;"
                     .. " append /data/notebooks/.probe;"
                     .. " fsync /data/notebooks/.probe;"
                     .. " truncate /data/notebooks/.probe"
           and fs.get(ROOT .. "/.probe") == "",
           "probe creates the root (fsyncing /data), appends, fsyncs and"
           .. " truncates", table.concat(fs.log, "; "))
    fs.reset_log()
    report(store:probe() and fs.calls.mkdir_excl == nil,
           "a second probe does not recreate the root")
    for _, c in ipairs{ { "append", "EROFS" }, { "append", "ENOSPC" },
                        { "fsync", "EROFS" }, { "fsync", "ENOSPC" } } do
        fs.clear_faults()
        fs.fault(c[1], c[2])
        local r, err = store:probe()
        report(r == nil and err == c[2] .. " /data/notebooks/.probe",
               "probe fails on " .. c[2] .. " from " .. c[1], err)
    end
    local fs2 = MemFS()
    local r, err = new_store(fs2):probe()
    report(r == nil and err == "ENOENT /data/notebooks",
           "probe without /data names the missing root", err)

    -- the root's entry in /data must be synced even when the first try
    -- fails after the mkdir: the retry sees EEXIST
    local fs3 = data_fs()
    local s3 = new_store(fs3)
    fs3.fault("fsync_dir", "EIO", { path = "/data", times = 1 })
    local r3, e3 = s3:probe()
    fs3.reset_log()
    local r4 = s3:probe()
    local retry = table.concat(fs3.log, "; ")
    fs3.reset_log()
    s3:probe()
    report(r3 == nil and e3 == "EIO /data" and r4
           and retry:find("^mkdir_excl /data/notebooks; fsync_dir /data; ") ~= nil
           and fs3.calls.fsync_dir == nil,
           "a failed fsync of /data after creating the root is retried on"
           .. " the next call, then never again", retry)
    fs3.crash()
    report(fs3.exists(ROOT), "model: the retried root survives a power cut")
end

-- 5c. create: ids, notebook.json, collisions.
local META_JSON = '{"format":"wilkbook-notebook","v":1,"id":"%s","created":%d,'
                  .. '"abs":[20966,15725,4095],"panel":[1872,1404,227]}\n'
do
    local fs = data_fs()
    local store = new_store(fs)
    local id = store:create(NOW + 0.75)
    local want = STAMP .. "-abcdef"
    report(id == want and J.is_id(id), "create: id is UTC stamp + 6 hex", id)
    report(fs.get(ROOT .. "/" .. want .. "/notebook.json")
           == string.format(META_JSON, want, NOW),
           "create: notebook.json bytes",
           (fs.get(ROOT .. "/" .. want .. "/notebook.json"):gsub("\n", "\\n")))
    report(table.concat(fs.log, "; ")
           == "mkdir_excl /data/notebooks; fsync_dir /data; mkdir_excl "
              .. ROOT .. "/" .. want .. "; fsync_dir /data/notebooks;"
              .. " write_atomic " .. ROOT .. "/" .. want .. "/notebook.json",
           "create: mkdir, fsync the root, write notebook.json atomically")

    fs.put(ROOT .. "/" .. STAMP .. "-000001/notebook.json", "x")
    fs.put(ROOT .. "/" .. STAMP .. "-000002/notebook.json", "x")
    fs.reset_log()
    store.rand = seq{ 1, 2, 3 }
    id = store:create(NOW)
    report(id == STAMP .. "-000003" and fs.calls.mkdir_excl == 3,
           "create: EEXIST retries with a new suffix", tostring(id))

    store.rand = seq{ 1 }
    local r, err = store:create(NOW)
    report(r == nil and err == "EEXIST /data/notebooks/" .. STAMP .. "-*",
           "create: a suffix source that keeps colliding gives up", err)

    store.rand = seq{ 0x1abcdef12 }
    report(store:create(NOW) == STAMP .. "-cdef12",
           "create: the suffix is the low 24 bits of rand()")

    fs.fault("mkdir_excl", "EROFS")
    store.rand = seq{ 0x10 }
    r, err = store:create(NOW)
    report(r == nil and err == "EROFS /data/notebooks/" .. STAMP .. "-000010",
           "create: another mkdir error is returned at once", err)
    fs.clear_faults()
    fs.fault("write_atomic", "ENOSPC")
    r, err = store:create(NOW)
    report(r == nil and err == "ENOSPC /data/notebooks/" .. STAMP
                               .. "-000010/notebook.json",
           "create: a failed notebook.json write is returned", err)
    fs.clear_faults()

    -- rand() must be an integer source: math.random() with no arguments
    -- would make every suffix 000000
    local refused = 0
    for _, v in ipairs{ 0.73, -1, 0 / 0, math.huge } do
        store.rand = seq{ v }
        local ok2, e2 = pcall(store.create, store, NOW + 7)
        if not ok2 and tostring(e2):find("rand%(%) must return") then
            refused = refused + 1
        end
    end
    report(refused == 4, "create: a fraction, a negative, NaN or infinity from"
           .. " rand() raises", refused .. "/4")

    local slashed = J.Store.new{ fs = fs, root = ROOT .. "//", cfg = cfg,
                                 rand = seq{ 0x42 } }
    report(slashed.root == ROOT and slashed:create(NOW + 9)
           == "20260921T141329Z-000042"
           and fs.get(ROOT .. "/20260921T141329Z-000042/notebook.json"),
           "a root given with trailing slashes is the same root", slashed.root)
end

-- 5d. list, 5e. open.
do
    local fs = data_fs()
    local store = new_store(fs)
    report(eq(store:list(), {}), "list: no root yet is an empty list")
    local ids = {}
    for i, t in ipairs{ NOW, NOW + 100, NOW + 50, NOW + 50 } do
        store.rand = seq{ i }
        ids[i] = store:create(t)
    end
    local d1 = ROOT .. "/" .. ids[1]
    for _, n in ipairs{ 10, -3, 0, 2, -12 } do
        fs.put(d1 .. "/" .. J.page_name(n), S(1) .. "\n")
    end
    for _, junk in ipairs{ "page-03.jsonl", "page--0.jsonl", "page-1.5.jsonl",
                           "page-x.jsonl", "page-3.jsonl.tmp", "page-+4.jsonl",
                           "page-99999999999999999999.jsonl" } do
        fs.put(d1 .. "/" .. junk, "")
    end
    fs.put(ROOT .. "/prefs.json", "{}\n")
    fs.put(ROOT .. "/.probe", "")
    fs.put(ROOT .. "/notanid/notebook.json", "x")
    fs.mkdirs(ROOT .. "/" .. STAMP .. "-0000aa")   -- create cut short
    fs.put(ROOT .. "/" .. STAMP .. "-0000bb/notebook.json", "{broken\n")
    fs.put(ROOT .. "/" .. STAMP .. "-0000cc/notebook.json",
           string.format(META_JSON, STAMP .. "-0000cc", NOW):gsub('"v":1', '"v":2'))
    fs.put(ROOT .. "/" .. STAMP .. "-0000dd/notebook.json",
           string.format(META_JSON, STAMP .. "-0000ee", NOW))
    -- a newer format that also adds a field, and a v1 file with a field v1
    -- does not have
    fs.put(ROOT .. "/" .. STAMP .. "-0000ff/notebook.json",
           (string.format(META_JSON, STAMP .. "-0000ff", NOW)
               :gsub('"v":1', '"v":2'):gsub("}\n$", ',"name":"x"}\n')))
    fs.put(ROOT .. "/" .. STAMP .. "-000100/notebook.json",
           (string.format(META_JSON, STAMP .. "-000100", NOW)
               :gsub("}\n$", ',"name":"x"}\n')))
    local l = store:list()
    local got = {}
    for i, e in ipairs(l) do got[i] = e.id:sub(-6) .. "@" .. (e.created - NOW) end
    report(list(got) == "{000002@100,000004@50,000003@50,000001@0}",
           "list: newest first, ties by id; only readable notebooks", list(got))
    report(list(l[4].pages) == "{-12,-3,0,2,10}" and #l[1].pages == 0,
           "list: pages sorted numerically; non-canonical names ignored",
           list(l[4].pages))
    fs.fault("listdir", "EIO", { path = ROOT, times = 1 })
    local r, err = store:list()
    report(r == nil and err == "EIO /data/notebooks", "list: a listdir error"
           .. " is returned", err)

    local nb = store:open(ids[1])
    report(nb and nb.id == ids[1] and nb.meta.created == NOW
           and list(nb.meta.abs) == "{20966,15725,4095}"
           and list(nb:pages()) == "{-12,-3,0,2,10}",
           "open: meta decoded, pages listed")
    local opens = {
        { "a path", "../etc", "EINVAL /data/notebooks/../etc" },
        { "uppercase hex", STAMP .. "-ABCDEF", "EINVAL /data/notebooks/"
          .. STAMP .. "-ABCDEF" },
        { "nil", nil, "EINVAL /data/notebooks/nil" },
        { "a missing notebook", STAMP .. "-123456", "ENOENT /data/notebooks/"
          .. STAMP .. "-123456/notebook.json" },
        { "no notebook.json", STAMP .. "-0000aa", "ENOENT /data/notebooks/"
          .. STAMP .. "-0000aa/notebook.json" },
        { "a corrupt notebook.json", STAMP .. "-0000bb", "EBADMSG /data/notebooks/"
          .. STAMP .. "-0000bb/notebook.json" },
        { "a newer format version", STAMP .. "-0000cc", "ENOTSUP /data/notebooks/"
          .. STAMP .. "-0000cc/notebook.json" },
        { "an id that disagrees with its directory", STAMP .. "-0000dd",
          "EBADMSG /data/notebooks/" .. STAMP .. "-0000dd/notebook.json" },
        { "a newer format version that adds a field", STAMP .. "-0000ff",
          "ENOTSUP /data/notebooks/" .. STAMP .. "-0000ff/notebook.json" },
        { "a v1 notebook.json with an unknown field", STAMP .. "-000100",
          "EBADMSG /data/notebooks/" .. STAMP .. "-000100/notebook.json" },
        { "an id with a trailing newline", STAMP .. "-000001\n",
          "EINVAL /data/notebooks/" .. STAMP .. "-000001\n" },
    }
    for _, c in ipairs(opens) do
        local o, e = store:open(c[2])
        report(o == nil and e == c[3], "open refuses " .. c[1],
               (tostring(e):gsub("\n", "\\n")))
    end
end

-- 5f. Page names.
do
    report(J.page_name(-3) == "page--3.jsonl" and J.page_name(0) == "page-0.jsonl"
           and J.page_name(12) == "page-12.jsonl",
           "page names: -3 -> page--3.jsonl, 0, 12")
    local bad = 0
    for n = -60, 60 do
        if J.page_number(J.page_name(n)) ~= n then bad = bad + 1 end
    end
    report(bad == 0, "page_number inverts page_name over -60..60")
    local rejected = 0
    for _, name in ipairs{ "page-03.jsonl", "page--0.jsonl", "page-+3.jsonl",
                           "page-1.5.jsonl", "page-.jsonl", "page-3.json",
                           "xpage-3.jsonl", "page-99999999999999999999.jsonl" } do
        if J.page_number(name) == nil then rejected = rejected + 1 end
    end
    report(rejected == 8, "page_number refuses non-canonical names", rejected .. "/8")
    report(not pcall(J.page_name, 1.5) and not pcall(J.page_name, "1"),
           "page_name refuses a non-integer")
    report(J.page_name(-0) == "page-0.jsonl"
           and J.page_number("page--9007199254740991.jsonl") == -J._codec.MAXI
           and J.page_number("page-9007199254740992.jsonl") == nil,
           "page names: -0 is page 0; the integer limit holds at both ends")

    -- Golden stamps from coreutils: date -u -d @T +%Y%m%dT%H%M%SZ
    local stamps = {
        { 0, "19700101T000000Z" }, { -1, "19691231T235959Z" },
        { 68256000, "19720301T000000Z" },
        { 951782400, "20000229T000000Z" }, { 951868799, "20000229T235959Z" },
        { 951868800, "20000301T000000Z" },
        { 1709164800, "20240229T000000Z" }, { 1709251199, "20240229T235959Z" },
        { 1790000000, "20260921T141320Z" },
        { 4107542399, "21000228T235959Z" }, { 4107542400, "21000301T000000Z" },
        { 253402300799, "99991231T235959Z" },
        { -62135596800, "00010101T000000Z" },
    }
    local wrong = {}
    for _, c in ipairs(stamps) do
        if J.utc_stamp(c[1]) ~= c[2] then wrong[#wrong + 1] = c[1] end
    end
    report(#wrong == 0 and J.utc_stamp(1790000000.999) == "20260921T141320Z",
           "utc_stamp matches coreutils date: epoch, leap days 2000 and 2024,"
           .. " no leap day in 2100, year 9999; fractions floor",
           #stamps .. " stamps, wrong: " .. list(wrong))

    local ids = 0
    for _, s in ipairs{ STAMP .. "-abcdef\n", STAMP .. "-abcde", STAMP .. "-abcdefa",
                        STAMP .. "-ABCDEF", STAMP .. "_abcdef", "x" .. STAMP .. "-abcdef",
                        "2026092T1413200Z-abcdef", "../" .. STAMP .. "-abcdef" } do
        if not J.is_id(s) then ids = ids + 1 end
    end
    report(ids == 8 and J.is_id(STAMP .. "-0a1b2c") and not J.is_id(nil),
           "is_id takes exactly stamp-6hex", ids .. "/8 refused")
end

-- 5g. append and fsync.
local function open_fresh()
    local fs = data_fs()
    local store = new_store(fs)
    local id = store:create(NOW)
    return fs, store, store:open(id), id
end

do
    local fs, _, nb = open_fresh()
    local p5 = nb:page_path(5)
    fs.reset_log()
    local lines, repaired = nb:page_lines(5)
    report(#lines == 0 and repaired == false and fs.calls.read == nil,
           "a blank page has no file and reads as no lines")
    local line = S(1)
    fs.reset_log()
    local ok = nb:append(5, line)
    report(ok and fs.calls.append == 1 and fs.get(p5) == line .. "\n"
           and fs.calls.fsync == nil and fs.calls.fsync_dir == nil,
           "append: one write of line..newline, no fsync")
    fs.reset_log()
    local r1, e1 = nb:append(5, "a\nb")
    local r2, e2 = nb:append(5, "")
    report(r1 == nil and r2 == nil and e1 == "EINVAL " .. p5 and e2 == e1
           and fs.calls.append == nil,
           "append refuses a line with a newline, and an empty line", e1)
    fs.reset_log()
    ok = nb:fsync(5)
    report(ok and table.concat(fs.log, "; ") == "fsync " .. p5
                  .. "; fsync_dir " .. nb.dir,
           "fsync: the page file, then its directory the first time",
           table.concat(fs.log, "; "))
    nb:append(5, S(2))
    fs.reset_log()
    nb:fsync(5)
    report(table.concat(fs.log, "; ") == "fsync " .. p5,
           "fsync: later fsyncs skip the directory")
    fs.reset_log()
    report(nb:fsync(5) and nb:fsync(9) and #fs.log == 0,
           "fsync of a clean or blank page makes no call (safe on every"
           .. " proximity-out)")

    fs.put(nb:page_path(-3), S(1) .. "\n")
    fs.put(nb:page_path(7), S(1) .. "\n")
    nb:page_lines(-3)
    nb:page_lines(7)
    nb:append(-3, S(2))
    nb:append(7, S(2))   -- existing and read: not new
    nb:append(2, S(1))
    fs.reset_log()
    -- The controller's leave: one fsync per page written, in page order.
    report(nb:fsync(-3) and nb:fsync(2) and nb:fsync(7)
           and table.concat(fs.log, "; ")
           == "fsync " .. nb:page_path(-3) .. "; fsync " .. nb:page_path(2)
              .. "; fsync_dir " .. nb.dir .. "; fsync " .. nb:page_path(7),
           "fsync: only the new file's directory is synced with it",
           table.concat(fs.log, "; "))
end

-- An existing page file must be read (and so repaired) before it takes an
-- append: an earlier session may have left it torn.
do
    local fs, _, nb = open_fresh()
    local p = nb:page_path(-1)
    local torn = S(1) .. "\n" .. S(2):sub(1, 9)
    fs.put(p, torn)
    fs.reset_log()
    local r, err = nb:append(-1, S(3))
    report(r == nil and err == "EINVAL " .. p and fs.calls.append == nil
           and fs.get(p) == torn,
           "append refuses an existing page it has not read; the torn file"
           .. " is untouched", err)
    local lines, repaired = nb:page_lines(-1)
    local ok = nb:append(-1, S(3))
    report(#lines == 1 and repaired and ok
           and fs.get(p) == S(1) .. "\n" .. S(3) .. "\n",
           "after page_lines repairs it, the page appends after the last"
           .. " whole record")

    fs.put(nb:page_path(-4), torn)
    fs.fault("truncate", "EROFS", { times = 1 })
    local l2, e2 = nb:page_lines(-4)
    local r3, e3 = nb:append(-4, S(3))
    report(l2 == nil and e2 == "EROFS " .. nb:page_path(-4) and r3 == nil
           and e3 == "EINVAL " .. nb:page_path(-4) and fs.get(nb:page_path(-4)) == torn,
           "a repair that fails is returned, and the page still refuses"
           .. " appends", e2)
    fs.fault("read", "EIO", { times = 1 })
    local l4, e4 = nb:page_lines(-4)
    report(l4 == nil and e4 == "EIO " .. nb:page_path(-4),
           "a read error from page_lines is returned with its path", e4)
end

-- 5h. Faults on append and fsync, and a torn write.
for _, c in ipairs{ { "append", "ENOSPC" }, { "append", "EROFS" } } do
    local fs, _, nb = open_fresh()
    local p = nb:page_path(1)
    nb:append(1, S(1))
    fs.fault(c[1], c[2], { times = 1 })
    local r, err = nb:append(1, S(2))
    fs.reset_log()
    local r2, err2 = nb:append(1, S(3))
    report(r == nil and err == c[2] .. " " .. p and r2 == nil
           and err2 == "EIO " .. p and fs.calls.append == nil,
           c[2] .. " on append is returned; the page takes no more appends", err)
    local lines, repaired = nb:page_lines(1)
    report(#lines == 1 and repaired == false and nb:append(1, S(2))
           and fs.get(p) == S(1) .. "\n" .. S(2) .. "\n",
           c[2] .. " on append: rereading the page re-enables appends")
end
do
    -- the first append of a blank page fails before the file exists
    local fs, _, nb = open_fresh()
    local p = nb:page_path(4)
    fs.fault("append", "EROFS", { times = 1 })
    local r, err = nb:append(4, S(1))
    local refused = nb:append(4, S(1)) == nil
    local lines, repaired = nb:page_lines(4)
    local ok = nb:append(4, S(1))
    fs.reset_log()
    nb:fsync(4)
    report(r == nil and err == "EROFS " .. p and refused and #lines == 0
           and repaired == false and ok and fs.get(p) == S(1) .. "\n"
           and table.concat(fs.log, "; ") == "fsync " .. p .. "; fsync_dir "
              .. nb.dir,
           "a failed first append on a blank page: rereading re-enables"
           .. " appends, and the file's directory is still fsynced", err)
end
for _, c in ipairs{ { "fsync", "ENOSPC" }, { "fsync", "EROFS" },
                    { "fsync_dir", "EIO" } } do
    local fs, _, nb = open_fresh()
    nb:append(1, S(1))
    fs.fault(c[1], c[2], { times = 1 })
    local r, err = nb:fsync(1)
    local where = c[1] == "fsync" and nb:page_path(1) or nb.dir
    fs.reset_log()
    local ok = nb:fsync(1)
    report(r == nil and err == c[2] .. " " .. where and ok
           and table.concat(fs.log, "; ") == "fsync " .. nb:page_path(1)
              .. "; fsync_dir " .. nb.dir,
           c[2] .. " on " .. c[1] .. " is returned; the next fsync retries"
           .. " file and directory", err)
end
do
    local fs, store, nb, id = open_fresh()
    local p = nb:page_path(1)
    nb:append(1, S(1))
    nb:append(1, S(2))
    nb:fsync(1)
    fs.fault("append", "EIO", { times = 1, torn = 7 })
    local r, err = nb:append(1, S(3))
    report(r == nil and err == "EIO " .. p
           and fs.get(p) == S(1) .. "\n" .. S(2) .. "\n" .. S(3):sub(1, 7),
           "a torn write leaves a 7-byte fragment and is returned", err)
    report(nb:append(1, S(3)) == nil, "the torn page refuses the next append")
    fs.reset_log()
    local lines, repaired = nb:page_lines(1)
    report(repaired and #lines == 2
           and table.concat(fs.log, "; "):find("truncate " .. p .. "; fsync " .. p, 1, true),
           "page_lines truncates the fragment and fsyncs before returning")
    local page = J.replay(lines, cfg)
    for _ = 1, 2 do
        local line = S(page.next_action)
        nb:append(1, line)
        J.apply(page, J.decode(line))
    end
    nb:fsync(1)
    fs.crash()
    local lines2 = store:open(id):page_lines(1)
    report(state(J.replay(lines2, cfg)) == "vis={1,2,3,4} undo=4 redo=nil next=5"
           .. " bad=0 ignored=0", "after the repair, two appends and a power"
           .. " cut, every complete record is back",
           state(J.replay(lines2, cfg)))
end

-- 5i. The torn tail at every byte offset of the last line.
local function torn_sweep(prefix_lines, last)
    local total, bad, first = 0, 0, nil
    for k = 0, #last do
        total = total + 1
        local fs, store, nb, id = open_fresh()
        local p = nb:page_path(-2)
        local body = #prefix_lines > 0 and table.concat(prefix_lines, "\n") .. "\n" or ""
        fs.put(p, body .. last:sub(1, k))
        local lines, repaired = nb:page_lines(-2)
        local ok = lines and #lines == #prefix_lines and repaired == (k > 0)
        -- the repair must already be durable when page_lines returns
        fs.crash()
        ok = ok and fs.get(p) == body
        nb = store:open(id)
        lines = nb:page_lines(-2)
        local page = J.replay(lines, cfg)
        local added = {}
        for i = 1, 2 do
            added[i] = S(page.next_action)
            ok = ok and nb:append(-2, added[i])
            J.apply(page, J.decode(added[i]))
        end
        ok = ok and nb:fsync(-2)
        fs.crash()
        local back = store:open(id):page_lines(-2)
        local want = {}
        for _, l in ipairs(prefix_lines) do want[#want + 1] = l end
        want[#want + 1], want[#want + 2] = added[1], added[2]
        ok = ok and eq(back, want) and J.replay(back, cfg).bad_lines == 0
             and dump(J.replay(back, cfg)) == dump(page)
        if not ok then
            bad = bad + 1
            first = first or k
        end
    end
    return total, bad, first
end
do
    local last = S(3, PEN, 12)
    local total, bad, first = torn_sweep({ S(1), S(2) }, last)
    report(bad == 0, "torn tail at every byte offset of the last line: repaired,"
           .. " durable, two appends, every complete record back",
           string.format("%d offsets, %d bad, first=%s", total, bad, tostring(first)))
    total, bad, first = torn_sweep({}, S(1, PEN, 2))
    report(bad == 0, "torn tail when the torn line is the only line",
           string.format("%d offsets, %d bad, first=%s", total, bad, tostring(first)))
end

-- 5j. The power-cut model: what the fsync rules buy.
do
    local fs, store, nb, id = open_fresh()
    nb:append(1, S(1))
    fs.crash()
    report(fs.get(nb:page_path(1)) == nil,
           "model: an append never fsynced is lost with its new file")
    fs, store, nb, id = open_fresh()
    nb:append(1, S(1))
    nb:fsync(1)
    nb:append(1, S(2))
    fs.crash()
    report(fs.get(nb:page_path(1)) == S(1) .. "\n",
           "an fsynced append survives; a later unsynced one is lost whole")
    report(#store:list() == 1 and store:open(id) ~= nil,
           "a created notebook survives a power cut (its root, directory and"
           .. " notebook.json were synced)")
end

-- 5k. prefs.json.
do
    local fs = data_fs()
    local store = new_store(fs)
    local t, err = store:load_prefs()
    report(eq(t, {}) and err == nil, "prefs: none yet is an empty table")
    local a, b = STAMP .. "-abcdef", STAMP .. "-000001"
    local prefs = { brush = "pencil", size = "M", mode = "stroke_erase",
                    rubber = "area", last_id = a,
                    last_page = { [a] = -3, [b] = 7 } }
    local ok = store:save_prefs(prefs)
    local bytes = fs.get(ROOT .. "/prefs.json")
    report(ok and bytes == '{"v":1,"brush":"pencil","size":"M","mode":"stroke_erase",'
           .. '"rubber":"area","last_id":"' .. a .. '","last_page":{"' .. b
           .. '":7,"' .. a .. '":-3}}\n', "prefs: version first, fixed key order, sorted map",
           (bytes:gsub("\n", "\\n")))
    report(eq(store:load_prefs(), prefs) and prefs.v == nil,
           "prefs: load gives back what was saved, without its version")
    store:save_prefs{ brush = "fine" }
    report(fs.get(ROOT .. "/prefs.json") == '{"v":1,"brush":"fine"}\n'
           and eq(store:load_prefs(), { brush = "fine" }),
           "prefs: absent fields are omitted")
    store:save_prefs{}
    report(fs.get(ROOT .. "/prefs.json") == '{"v":1}\n' and eq(store:load_prefs(), {}),
           "prefs: nothing chosen is just the version")
    fs.put(ROOT .. "/prefs.json", '{"brush":"fine"}\n')
    report(eq(store:load_prefs(), { brush = "fine" }),
           "prefs: a file without a version is version 1")
    fs.put(ROOT .. "/prefs.json", '{"v":2,"brush":"fine"}\n')
    t, err = store:load_prefs()
    report(eq(t, {}) and err == "EPROTO /data/notebooks/prefs.json is version 2, not 1",
           "prefs: another version is not read as this one", err)
    store:save_prefs{ brush = "fine" }
    fs.fault("write_atomic", "ENOSPC", { times = 1 })
    local r, e = store:save_prefs(prefs)
    report(r == nil and e == "ENOSPC /data/notebooks/prefs.json"
           and eq(store:load_prefs(), { brush = "fine" }),
           "prefs: a failed save leaves the previous file whole", e)
    fs.put(ROOT .. "/prefs.json", '{"brush":"fine"')
    t, err = store:load_prefs()
    report(eq(t, {}) and err == "EBADMSG /data/notebooks/prefs.json",
           "prefs: a corrupt file loads as empty, with the reason", err)
    report(not pcall(store.save_prefs, store, { colour = "red" }),
           "prefs: an unknown field raises rather than being dropped")
end

------------------------------------------------------------------------
-- 6. Replay time on a large page (reported, not gated).
------------------------------------------------------------------------

do
    local NS, NP = 2000, 300
    local lines, bytes = {}, 0
    for a = 1, NS do
        local x, y, p = 2000 + rnd(16000), 2000 + rnd(11000), 2000
        local points = {}
        for i = 1, NP do
            x, y = x + rnd(61) - 30, y + rnd(61) - 30
            p = math.max(0, math.min(4095, p + rnd(201) - 100))
            points[i] = { t = T0 + i * 2770, rawx = x, rawy = y, p = p,
                          tx = rnd(41) - 20, ty = rnd(41) - 20 }
        end
        lines[a] = J.encode(J.stroke_record(a, PEN, 1, T0, points, false,
                                            { 0, 0, 10, 10 }))
        bytes = bytes + #lines[a] + 1
    end
    collectgarbage()
    local c0 = os.clock()
    local page = J.replay(lines, cfg)
    local dt = os.clock() - c0
    local npts, sum = 0, 0
    for _, e in ipairs(page.strokes) do
        npts = npts + #e.points
        sum = sum + math.floor(e.points[#e.points].x + e.points[#e.points].y)
    end
    io.stderr:write(string.format("replay %d strokes x %d samples (%.1f MB):"
                                  .. " %.0f ms, %.1f MB Lua heap\n", NS, NP,
                                  bytes / 1e6, dt * 1000,
                                  collectgarbage("count") / 1024))
    report(#page.strokes == NS and npts == NS * NP and page.bad_lines == 0,
           "a 2000-stroke x 300-sample page replays whole",
           string.format("%d strokes, %d points, checksum %d", #page.strokes,
                         npts, sum))
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
