--[[--
nb_journal -- the notebook's on-disk format, its replay, and its store.

Pure: no KOReader modules and no io/os calls.  Every file operation goes
through an injected fs table (main.lua implements it with ffi; the host
test, pinenote/tools/koreader-input/test-notebook-journal.lua, implements
it in memory with fault injection and a power-cut model), so the whole
journal runs on any luajit.

Layout under the store root (default /data/notebooks):

  <id>/notebook.json   written once, atomically
  <id>/page-<n>.jsonl  append-only, one record per line; n is any integer
                       (page--3.jsonl is page -3); a blank page has no file
  prefs.json           rewritten atomically (tmp, fsync, rename, fsync dir);
                       "v" is its format version, and the settings in it
                       are only those the user chose (nb_controller)

Records are a restricted JSON: objects with string keys; values that are
integers, strings of [A-Za-z0-9_.-], booleans or integer arrays; keys in
a fixed order per record kind; no whitespace.  The decoder accepts only
what the encoder writes, so a line it accepts re-encodes to the same
bytes, and damage anywhere in a line shows up as an undecodable line
rather than as a plausible wrong value.

  {"k":"s",...}    a stroke (pen ink or area erase), drawn in file order
  {"k":"x",...}    a stroke erase: hides the listed stroke actions
  {"k":"u","a":T}  undo action T
  {"k":"r","a":T}  redo action T

Action ids are per page: 1 + the largest id the file has seen.

Undo and redo are a strict stack machine.  A u record must name the last
active action and an r record the top of the redo stack.  A record that
names anything else changes nothing and is counted in page.ignored, so a
damaged or hand-edited file never undoes out of order.  New ink (s or x)
clears the redo stack.  J.apply is replay's own step function, so a page
kept current in memory with J.apply is the page a reread would give.

Durability (doc/notebook.md, "The journal"):
  * one write(2) per stroke at pen-up.  The controller fsyncs only when
    the pen leaves range (a proximity-out that lasts), on close and on
    suspend, never while the pen is in range: the Stylus evdev buffer
    holds ~100 ms of reports, and a blocking fsync on KOReader's only
    thread could overflow it;
  * a page file's directory is fsynced the first time the file is
    created, and the root's parent when the root is created;
  * page_lines repairs a torn tail (truncate to the last newline, fsync)
    before returning.  It is the one exception to append-only, and it
    means a new record can never join a fragment.
--]]

local Config = require("nb_config")
local Geom = require("nb_geom")

local J = {}

local byte, char, sub = string.byte, string.char, string.sub
local find, match = string.find, string.match
local gmatch, gsub = string.gmatch, string.gsub
local format = string.format
local concat, sort = table.concat, table.sort
local floor, ceil = math.floor, math.ceil

-- The largest integer a double holds exactly.  t0 in unix microseconds
-- (~1.8e15) takes 16 digits, so the codec's limit is the double's, not a
-- digit count.
local MAXI = 2^53 - 1

local QUOTE, COMMA, MINUS, COLON = 34, 44, 45, 58
local LBRACK, RBRACK, LBRACE, RBRACE = 91, 93, 123, 125

local FORMAT = "wilkbook-notebook"
local VERSION = 1
-- prefs.json's own format version, which migrations will key on.
local PREFS_VERSION = 1

------------------------------------------------------------------------
-- The restricted-JSON codec.
------------------------------------------------------------------------

-- Each field is { key, type, optional }; the list order is the byte
-- order on disk.
local function schema(fields)
    local index = {}
    for i, f in ipairs(fields) do index[f[1]] = i end
    fields.index = index
    return fields
end

local RECORD = {
    s = schema{ {"k", "str"}, {"a", "int"}, {"tool", "str"}, {"brush", "str"},
                {"size", "str"}, {"st", "ints"}, {"comp", "str"},
                {"pat", "str"}, {"rot", "int"}, {"t0", "int"}, {"gap", "int"},
                {"bb", "ints"}, {"d", "ints"} },
    x = schema{ {"k", "str"}, {"a", "int"}, {"ids", "ints"} },
    u = schema{ {"k", "str"}, {"a", "int"} },
    r = schema{ {"k", "str"}, {"a", "int"} },
}

local META = schema{ {"format", "str"}, {"v", "int"}, {"id", "str"},
                     {"created", "int"}, {"abs", "ints"}, {"panel", "ints"} }

local PREFS = schema{ {"v", "int", true},
                      {"brush", "str", true}, {"size", "str", true},
                      {"mode", "str", true}, {"rubber", "str", true},
                      {"last_id", "str", true}, {"last_page", "map", true} }

local function is_int(v)
    return type(v) == "number" and v == floor(v) and v >= -MAXI and v <= MAXI
end

-- Semantic checks shared by encode and decode, so the encoder can never
-- write a line the decoder would reject.  Each returns nil or a reason.
local function ids_ok(v)
    for i = 1, #v do
        if v[i] < 1 then return false end
    end
    return true
end

local CHECK = {
    s = function(r)
        if r.a < 1 then return "action id below 1" end
        if r.tool ~= "pen" and r.tool ~= "eraser" then return "bad tool" end
        if #r.st ~= 7 then return "st needs 7 values" end
        if r.gap ~= 0 and r.gap ~= 1 then return "gap is not 0 or 1" end
        if #r.bb ~= 4 then return "bb needs 4 values" end
        if #r.d == 0 or #r.d % 6 ~= 0 then return "d is not whole samples" end
    end,
    x = function(r)
        if r.a < 1 then return "action id below 1" end
        if not ids_ok(r.ids) then return "erased id below 1" end
    end,
    u = function(r)
        if r.a < 1 then return "action id below 1" end
    end,
    r = function(r)
        if r.a < 1 then return "action id below 1" end
    end,
}

local function bad_value(what, key, v)
    error(format("nb_journal: %s for %s: %s", what, key, tostring(v)), 0)
end

local ENC = {}

function ENC.int(v, key)
    if not is_int(v) then bad_value("not an integer", key, v) end
    return format("%d", v)
end

function ENC.str(v, key)
    if type(v) ~= "string" or find(v, "[^A-Za-z0-9_.-]") then
        bad_value("not a restricted string", key, v)
    end
    return '"' .. v .. '"'
end

function ENC.bool(v, key)
    if type(v) ~= "boolean" then bad_value("not a boolean", key, v) end
    return v and "true" or "false"
end

function ENC.ints(v, key)
    if type(v) ~= "table" then bad_value("not an array", key, v) end
    local n, out = 0, {}
    for i = 1, #v do
        local x = v[i]
        if not is_int(x) then bad_value("not an integer", key, x) end
        out[i] = format("%d", x)
    end
    -- anything outside 1..#v (a hole, a named field) would be dropped
    -- silently and break the round trip
    for _ in pairs(v) do n = n + 1 end
    if n ~= #v then bad_value("not a plain array", key, n) end
    return "[" .. concat(out, ",") .. "]"
end

-- A map of restricted strings to integers, keys sorted so the bytes are
-- deterministic (prefs.json's last_page).
function ENC.map(v, key)
    if type(v) ~= "table" then bad_value("not a map", key, v) end
    local keys = {}
    for k, x in pairs(v) do
        ENC.str(k, key)
        ENC.int(x, key)
        keys[#keys + 1] = k
    end
    sort(keys)
    local out = {}
    for i, k in ipairs(keys) do
        out[i] = '"' .. k .. '":' .. format("%d", v[k])
    end
    return "{" .. concat(out, ",") .. "}"
end

local function encode_obj(t, sch)
    for k in pairs(t) do
        if not sch.index[k] then bad_value("unknown field", tostring(k), "") end
    end
    local parts, n = {}, 0
    for _, f in ipairs(sch) do
        local v = t[f[1]]
        if v ~= nil then
            n = n + 1
            parts[n] = '"' .. f[1] .. '":' .. ENC[f[2]](v, f[1])
        elseif not f[3] then
            bad_value("missing field", f[1], "nil")
        end
    end
    return "{" .. concat(parts, ",") .. "}"
end

-- Decoders take (s, i) and return value, next position, or nil and the
-- position of the fault.  Integers are canonical: no leading zeros, no
-- "-0", no fraction or exponent, and within MAXI.  A leading zero needs
-- no check of its own: after a lone 0 the next byte must be a separator,
-- so "01" fails there.
local function parse_int(s, i)
    local b = byte(s, i)
    local neg = b == MINUS
    if neg then
        i = i + 1
        b = byte(s, i)
    end
    if b == nil or b < 48 or b > 57 then return nil, i end
    local v, j = b - 48, i + 1
    b = byte(s, j)
    if v == 0 then
        if neg then return nil, i end
        return 0, j
    end
    while b and b >= 48 and b <= 57 do
        v = v * 10 + (b - 48)
        j = j + 1
        b = byte(s, j)
    end
    -- rounding is monotonic, so a true value past MAXI never computes
    -- to one within it
    if v > MAXI then return nil, i end
    return neg and -v or v, j
end

-- parse_int inlined: a stroke's d array is nearly all of a page's bytes,
-- and this loop is what replay's time goes to.
local function parse_ints(s, i)
    if byte(s, i) ~= LBRACK then return nil, i end
    i = i + 1
    local out, n = {}, 0
    local b = byte(s, i)
    if b == RBRACK then return out, i + 1 end
    while true do
        local neg = b == MINUS
        if neg then
            i = i + 1
            b = byte(s, i)
        end
        if b == nil or b < 48 or b > 57 then return nil, i end
        local v, j = b - 48, i + 1
        b = byte(s, j)
        if v == 0 then
            if neg then return nil, i end
        else
            while b and b >= 48 and b <= 57 do
                v = v * 10 + (b - 48)
                j = j + 1
                b = byte(s, j)
            end
            if v > MAXI then return nil, i end
            if neg then v = -v end
        end
        n = n + 1
        out[n] = v
        if b == RBRACK then return out, j + 1 end
        if b ~= COMMA then return nil, j end
        i = j + 1
        b = byte(s, i)
    end
end

local DEC = { int = parse_int, ints = parse_ints }

function DEC.str(s, i)
    if byte(s, i) ~= QUOTE then return nil, i end
    local _, e = find(s, '^[A-Za-z0-9_.-]*"', i + 1)
    if not e then return nil, i end
    return sub(s, i + 1, e - 1), e + 1
end

function DEC.bool(s, i)
    if sub(s, i, i + 3) == "true" then return true, i + 4 end
    if sub(s, i, i + 4) == "false" then return false, i + 5 end
    return nil, i
end

function DEC.map(s, i)
    if byte(s, i) ~= LBRACE then return nil, i end
    i = i + 1
    local out, prev = {}, nil
    if byte(s, i) == RBRACE then return out, i + 1 end
    while true do
        local k, v
        k, i = DEC.str(s, i)
        if k == nil then return nil, i end
        -- strictly ascending, as the encoder sorts: this also rules out
        -- a duplicate key
        if prev and k <= prev then return nil, i end
        if byte(s, i) ~= COLON then return nil, i end
        v, i = parse_int(s, i + 1)
        if v == nil then return nil, i end
        out[k] = v
        prev = k
        local b = byte(s, i)
        if b == RBRACE then return out, i + 1 end
        if b ~= COMMA then return nil, i end
        i = i + 1
    end
end

local function at(why, i)
    return format("%s at byte %d", why, i)
end

local function decode_obj(s, sch)
    if byte(s, 1) ~= LBRACE then return nil, at("expected {", 1) end
    local t, i, j = {}, 2, 1
    if byte(s, i) ~= RBRACE then
        while true do
            local key
            key, i = DEC.str(s, i)
            if key == nil then return nil, at("bad key", i) end
            if byte(s, i) ~= COLON then return nil, at("expected :", i) end
            i = i + 1
            -- keys come in schema order; only an optional field may be
            -- absent, which also rules out duplicates and unknown keys
            local f = sch[j]
            while f and f[1] ~= key do
                if not f[3] then return nil, at("missing " .. f[1], i) end
                j = j + 1
                f = sch[j]
            end
            if not f then return nil, at("unexpected key " .. key, i) end
            local v
            v, i = DEC[f[2]](s, i)
            if v == nil then return nil, at("bad value for " .. key, i) end
            t[key] = v
            j = j + 1
            local b = byte(s, i)
            if b == RBRACE then break end
            if b ~= COMMA then return nil, at("expected , or }", i) end
            i = i + 1
        end
    end
    if i ~= #s then return nil, at("trailing bytes", i + 1) end
    for k = j, #sch do
        if not sch[k][3] then return nil, at("missing " .. sch[k][1], i) end
    end
    return t
end

-- A whole-file document (notebook.json, prefs.json) ends in one newline.
local function decode_doc(s, sch)
    if byte(s, #s) ~= 10 then return nil, "no final newline" end
    return decode_obj(sub(s, 1, #s - 1), sch)
end

local function encode_doc(t, sch)
    return encode_obj(t, sch) .. "\n"
end

-- Raises on a record outside the format: that is a caller bug, and a
-- silent nil would surface later as a write of "nil".
function J.encode(rec)
    local kind = type(rec) == "table" and rec.k
    local sch = RECORD[kind]
    if not sch then bad_value("unknown record kind", "k", kind) end
    local line = encode_obj(rec, sch)
    local why = CHECK[kind](rec)
    if why then bad_value(why, "record", line) end
    return line
end

function J.decode(line)
    if type(line) ~= "string" then return nil, "not a string" end
    local kind = match(line, '^{"k":"(%l)"')
    local sch = RECORD[kind]
    if not sch then return nil, "unknown record kind" end
    local rec, err = decode_obj(line, sch)
    if not rec then return nil, err end
    local why = CHECK[kind](rec)
    if why then return nil, why end
    return rec
end

------------------------------------------------------------------------
-- Records and samples.
------------------------------------------------------------------------

local function round(v)
    return floor(v + 0.5)
end

--- Build a stroke record.  points are { {t=us, rawx=, rawy=, p=, tx=, ty=} }
-- with t on the realtime clock; style is nb_brush's; bb is the stroke's
-- physical-px box {x0, y0, x1, y1} including its radius, rounded outward.
function J.stroke_record(action, style, rot, t0_us, points, gap, bb)
    local n = #points
    if n == 0 then
        error("nb_journal.stroke_record: a stroke needs a sample", 2)
    end
    local t0 = round(t0_us)
    local d = {}
    -- the first sample is stored against zero (t against t0), so one
    -- delta loop writes it absolute and the rest relative
    local pt, px, py, pp, ptx, pty = t0, 0, 0, 0, 0, 0
    local k = 0
    for i = 1, n do
        local s = points[i]
        local t = round(s.t)
        -- realtime can step backwards; a clamped delta keeps the stored
        -- times monotonic
        if t < pt then t = pt end
        local x, y = round(s.rawx), round(s.rawy)
        local p, tx, ty = round(s.p or 0), round(s.tx or 0), round(s.ty or 0)
        d[k + 1], d[k + 2], d[k + 3] = t - pt, x - px, y - py
        d[k + 4], d[k + 5], d[k + 6] = p - pp, tx - ptx, ty - pty
        k = k + 6
        pt, px, py, pp, ptx, pty = t, x, y, p, tx, ty
    end
    return {
        k = "s", a = action, tool = style.tool,
        brush = style.brush or "", size = style.size or "",
        -- absent fields take the values that make them inert: gamma 1,
        -- and a zero density window only pattern brushes read
        st = { round(style.rmin * 100), round(style.rmax * 100),
               round((style.gamma or 1) * 100), round(style.plo or 0),
               round(style.phi or 0), round((style.dlo or 0) * 100),
               round((style.dhi or 0) * 100) },
        comp = style.comp, pat = style.pat, rot = rot, t0 = t0,
        gap = (gap == true or gap == 1) and 1 or 0,
        bb = { floor(bb[1]), floor(bb[2]), ceil(bb[3]), ceil(bb[4]) },
        d = d,
    }
end

--- The style a record draws with: nb_brush's style quantized to the
-- stored hundredths.  Inking live with this instead of the brush's own
-- style makes the live stroke and its replay the same pixels.
function J.style(rec)
    local st = rec.st
    return {
        brush = rec.brush, size = rec.size, tool = rec.tool,
        rmin = st[1] / 100, rmax = st[2] / 100, gamma = st[3] / 100,
        plo = st[4], phi = st[5], comp = rec.comp, pat = rec.pat,
        dlo = st[6] / 100, dhi = st[7] / 100,
    }
end

--- The record's samples as absolute digitizer values, t on the realtime
-- clock: the inverse of stroke_record's delta coding.
function J.samples(rec)
    local d, out = rec.d, {}
    local t, x, y, p, tx, ty = rec.t0, 0, 0, 0, 0, 0
    for i = 1, #d, 6 do
        t, x, y = t + d[i], x + d[i + 1], y + d[i + 2]
        p, tx, ty = p + d[i + 3], tx + d[i + 4], ty + d[i + 5]
        out[#out + 1] = { t = t, rawx = x, rawy = y, p = p, tx = tx, ty = ty }
    end
    return out
end

--- The record's samples in physical px, as nb_brush draws them.
-- p stays in raw pressure units: the style's plo/phi window is raw.
-- cfg supplies W, H, abs_x_max and abs_y_max (default nb_config).
function J.points_px(rec, cfg)
    cfg = cfg or Config
    local d, out, n = rec.d, {}, 0
    local W, H = cfg.W, cfg.H
    local xmax, ymax = cfg.abs_x_max, cfg.abs_y_max
    local raw_to_px = Geom.raw_to_px
    local x, y, p = 0, 0, 0
    for i = 1, #d, 6 do
        x, y, p = x + d[i + 1], y + d[i + 2], p + d[i + 3]
        n = n + 1
        out[n] = { x = raw_to_px(x, xmax, W), y = raw_to_px(y, ymax, H), p = p }
    end
    return out
end

------------------------------------------------------------------------
-- Replay.
------------------------------------------------------------------------

local function new_page(cfg)
    return {
        strokes = {},        -- visible stroke entries, file order
        next_action = 1,
        undo_target = nil,
        redo_target = nil,
        bad_lines = 0,       -- undecodable lines, skipped
        ignored = 0,         -- decodable records that changed nothing
        _cfg = cfg,
        _acts = {},          -- [action] = { kind, active, ... }
        _order = {},         -- s and x actions, file order
        _redo = {},          -- redo stack, top last
    }
end

local function last_active(page)
    local order, acts = page._order, page._acts
    for i = #order, 1, -1 do
        if acts[order[i]].active then return order[i] end
    end
    return nil
end

-- An x hides its targets while it is active.  A count rather than a flag,
-- because two stroke erases can name the same stroke.
local function set_active(page, act, on)
    act.active = on
    if act.kind == "x" then
        local acts, dh = page._acts, on and 1 or -1
        for _, id in ipairs(act.targets) do
            acts[id].hidden = acts[id].hidden + dh
        end
    end
end

local function rebuild(page)
    local out, n, acts = {}, 0, page._acts
    for _, a in ipairs(page._order) do
        local act = acts[a]
        if act.kind == "s" and act.active and act.hidden == 0 then
            n = n + 1
            out[n] = act.entry
        end
    end
    page.strokes = out
end

-- One record into the page.  Returns true when page.strokes must be
-- rebuilt; a new stroke is always visible, so it is appended in place.
local function step(page, rec)
    local a, kind, acts = rec.a, rec.k, page._acts
    if a >= page.next_action then page.next_action = a + 1 end
    if kind == "s" or kind == "x" then
        if kind == "x" then
            for _, id in ipairs(rec.ids) do
                if id >= page.next_action then page.next_action = id + 1 end
            end
        end
        -- a repeated action id is a duplicated line: drawing it twice
        -- would make one undo leave a copy behind
        if acts[a] then
            page.ignored = page.ignored + 1
            return false
        end
        local act
        if kind == "s" then
            act = { kind = "s", active = true, hidden = 0, entry = {
                a = a, rec = rec, style = J.style(rec), bb = rec.bb,
                points = J.points_px(rec, page._cfg),
            } }
        else
            -- ids resolve now, to strokes already in the file, so an x can
            -- never hide a stroke written after it
            local targets = {}
            for _, id in ipairs(rec.ids) do
                local t = acts[id]
                if t and t.kind == "s" then targets[#targets + 1] = id end
            end
            act = { kind = "x", active = false, targets = targets }
        end
        acts[a] = act
        page._order[#page._order + 1] = a
        page._redo = {}
        page.redo_target = nil
        page.undo_target = a
        if kind == "s" then
            page.strokes[#page.strokes + 1] = act.entry
            return false
        end
        set_active(page, act, true)
        return true
    elseif kind == "u" then
        if a ~= page.undo_target then
            page.ignored = page.ignored + 1
            return false
        end
        set_active(page, acts[a], false)
        page._redo[#page._redo + 1] = a
        page.redo_target = a
        page.undo_target = last_active(page)
        return true
    else
        if a ~= page.redo_target then
            page.ignored = page.ignored + 1
            return false
        end
        local redo = page._redo
        redo[#redo] = nil
        page.redo_target = redo[#redo]
        set_active(page, acts[a], true)
        page.undo_target = a
        return true
    end
end

--- Replay a page file's lines.  cfg supplies W, H, abs_x_max and
-- abs_y_max for the px points (default nb_config); the page keeps it for
-- J.apply.  replay({}, cfg) is a blank page.
function J.replay(lines, cfg)
    local page = new_page(cfg or Config)
    local stale = false
    for i = 1, #lines do
        local line = lines[i]
        local rec = J.decode(line)
        if rec then
            if step(page, rec) then stale = true end
        else
            page.bad_lines = page.bad_lines + 1
            -- a damaged line may still show its action id; reserving it
            -- keeps a new action from reusing an id an undo might name
            local a = type(line) == "string"
                      and tonumber(match(line, '"a":(%d+)'))
            if a and a <= MAXI and a >= page.next_action then
                page.next_action = a + 1
            end
        end
    end
    if stale then rebuild(page) end
    return page
end

--- Apply one record (already appended) to a page in memory, exactly as
-- replay would.  page.strokes is replaced when an undo, redo or erase
-- changes it, and appended to in place for a new stroke.
function J.apply(page, rec)
    if step(page, rec) then rebuild(page) end
    return page
end

------------------------------------------------------------------------
-- Names.
------------------------------------------------------------------------

--- A unix time as UTC YYYYMMDDTHHMMSSZ.  Civil-from-days arithmetic
-- (H. Hinnant's algorithm) rather than os.date keeps the module free of
-- os calls and of the process's time zone.
function J.utc_stamp(unix_s)
    local t = floor(unix_s)
    local days = floor(t / 86400)
    local secs = t - days * 86400
    local z = days + 719468
    local era = floor(z / 146097)
    local doe = z - era * 146097
    local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524)
                       - floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
    local mp = floor((5 * doy + 2) / 153)
    local day = doy - floor((153 * mp + 2) / 5) + 1
    local month = mp < 10 and mp + 3 or mp - 9
    local year = yoe + era * 400 + (month <= 2 and 1 or 0)
    return format("%04d%02d%02dT%02d%02d%02dZ", year, month, day,
                  floor(secs / 3600), floor(secs % 3600 / 60), secs % 60)
end

local ID_PATTERN = "^%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ%-"
                   .. ("[0-9a-f]"):rep(6) .. "$"

function J.is_id(s)
    return type(s) == "string" and find(s, ID_PATTERN) ~= nil
end

function J.page_name(n)
    if not is_int(n) then
        error("nb_journal: page number is not an integer: " .. tostring(n), 2)
    end
    return format("page-%d.jsonl", n)
end

-- Only the canonical spelling counts: page-03 or page--0 would be a
-- second file for page 3 or page 0.
function J.page_number(name)
    local n = tonumber(match(name, "^page%-(%-?%d+)%.jsonl$"))
    if n and is_int(n) and J.page_name(n) == name then return n end
    return nil
end

------------------------------------------------------------------------
-- The store.
------------------------------------------------------------------------

local MAX_ID_TRIES = 16

local function fail(errname, path)
    return nil, (errname or "EIO") .. " " .. path
end

local function parent(path)
    local p = match(path, "^(.*)/[^/]*$")
    if p == nil then return "." end
    if p == "" then return "/" end
    return p
end

local function has_opt(opts, name)
    return find("," .. opts .. ",", "," .. name .. ",", 1, true) ~= nil
end

-- One /proc/self/mountinfo line: id parent maj:min root point options
-- [optional...] - fstype source super-options.
local function parse_mount(line)
    local f, n = {}, 0
    for w in gmatch(line, "%S+") do
        n = n + 1
        f[n] = w
    end
    local sep
    for i = 7, n do
        if f[i] == "-" then
            sep = i
            break
        end
    end
    if not sep or n < sep + 3 then return nil end
    local point = gsub(f[5], "\\(%d%d%d)", function(o)
        return char(tonumber(o, 8))
    end)
    return { dev = f[3], point = point, opts = f[6], fstype = f[sep + 1],
             super = f[sep + 3] }
end

local function covers(point, path)
    return point == "/" or path == point
        or sub(path, 1, #point + 1) == point .. "/"
end

local function page_numbers(names)
    local out = {}
    for _, name in ipairs(names) do
        local n = J.page_number(name)
        if n then out[#out + 1] = n end
    end
    sort(out)
    return out
end

local Store = {}
Store.__index = Store
J.Store = Store

local Notebook = {}
Notebook.__index = Notebook

--- Store.new{fs=, root=, cfg=, rand=}.  rand() returns a non-negative
-- integer; its low 24 bits make an id's suffix.
function Store.new(o)
    local self = setmetatable({}, Store)
    self.fs = assert(o.fs, "nb_journal.Store: fs is required")
    self.cfg = o.cfg or Config
    self.root = match(o.root or self.cfg.notebooks_root, "^(.-)/*$")
    self.rand = o.rand
    return self
end

--- Is the root on the real data partition?  The placeholder the reader
-- image leaves when p7 does not mount is a plain directory on the OS
-- root, which is ext4 too, so the covering mount must be its own, not
-- merely ext4 (pinenote/systems/pinenote-reader.scm, the library
-- fallback).  A bind of the OS root counts as the placeholder.
function Store:check_data(mountinfo)
    if type(mountinfo) ~= "string" then return false, "no mountinfo" end
    local best, rootdev
    for line in gmatch(mountinfo, "[^\n]+") do
        local m = parse_mount(line)
        if m then
            if m.point == "/" then rootdev = m.dev end
            -- the longest cover wins; of two at one point, the later one
            -- is mounted on top
            if covers(m.point, self.root)
               and (not best or #m.point >= #best.point) then
                best = m
            end
        end
    end
    if not best then return false, "no mount covers " .. self.root end
    if best.point == "/" or best.dev == rootdev then
        return false, self.root .. " is on the OS root filesystem,"
                      .. " not the data partition"
    end
    if best.fstype ~= "ext4" then
        return false, best.point .. " is " .. best.fstype .. ", not ext4"
    end
    -- ext4's errors=remount-ro marks only the superblock read-only; the
    -- per-mount options still say rw
    if not has_opt(best.opts, "rw") or has_opt(best.super, "ro") then
        return false, best.point .. " is mounted read-only"
    end
    return true
end

function Store:_ensure_root()
    if self._root_ok then return true end
    local fs, up = self.fs, parent(self.root)
    local ok, err = fs.mkdir_excl(self.root)
    if ok then
        self._root_new = true
    elseif err ~= "EEXIST" then
        return fail(err, self.root)
    end
    -- a root this store made stays unsynced until its parent's fsync
    -- succeeds: after a failed one, the retry's EEXIST must not skip it
    if self._root_new then
        ok, err = fs.fsync_dir(up)
        if not ok then return fail(err, up) end
        self._root_new = nil
    end
    self._root_ok = true
    return true
end

--- One real append and fsync on the data partition: a read-only or full
-- /data fails here, at open, rather than at the first pen-up.
function Store:probe()
    local ok, err = self:_ensure_root()
    if not ok then return nil, err end
    local fs, path = self.fs, self.root .. "/.probe"
    ok, err = fs.append(path, "probe\n")
    if not ok then return fail(err, path) end
    ok, err = fs.fsync(path)
    if not ok then return fail(err, path) end
    -- keep the probe file from growing across opens
    ok, err = fs.truncate(path, 0)
    if not ok then return fail(err, path) end
    return true
end

function Store:_read_meta(id)
    local path = self.root .. "/" .. id .. "/notebook.json"
    local s, err = self.fs.read(path)
    if not s then return fail(err, path) end
    -- a newer format is refused, not misread: an older generation can be
    -- booted after a newer one wrote the notebook.  The version is read
    -- before the strict decode, because a newer format may add fields
    -- this decoder refuses, and must not read as corrupt.
    local v = tonumber(match(s, '^{"format":"wilkbook%-notebook","v":(%d+),'))
    if v and v ~= VERSION then return fail("ENOTSUP", path) end
    local meta = decode_doc(s, META)
    if not meta or meta.format ~= FORMAT or meta.id ~= id
       or #meta.abs ~= 3 or #meta.panel ~= 3 then
        return fail("EBADMSG", path)
    end
    return meta
end

--- Every readable notebook, newest first.  A directory without a valid
-- notebook.json (a create cut short between mkdir and the write) is left
-- out.
function Store:list()
    local fs = self.fs
    local names, err = fs.listdir(self.root)
    if not names then
        if err == "ENOENT" then return {} end
        return fail(err, self.root)
    end
    local out = {}
    for _, name in ipairs(names) do
        if J.is_id(name) then
            local meta = self:_read_meta(name)
            if meta then
                local pages = fs.listdir(self.root .. "/" .. name)
                out[#out + 1] = { id = name, created = meta.created,
                                  pages = page_numbers(pages or {}) }
            end
        end
    end
    sort(out, function(a, b)
        if a.created ~= b.created then return a.created > b.created end
        return a.id > b.id
    end)
    return out
end

function Store:create(now_unix_s)
    local ok, err = self:_ensure_root()
    if not ok then return nil, err end
    local fs, cfg = self.fs, self.cfg
    assert(self.rand, "nb_journal.Store: create needs rand")
    local stamp = J.utc_stamp(now_unix_s)
    for _ = 1, MAX_ID_TRIES do
        local r = self.rand()
        -- math.random() with no arguments is a float in [0, 1), which
        -- would make every suffix 000000 without a word
        if not is_int(r) or r < 0 then
            error("nb_journal.Store: rand() must return a non-negative"
                  .. " integer, got " .. tostring(r), 2)
        end
        local suffix = r % 0x1000000
        local id = stamp .. "-" .. format("%06x", suffix)
        local dir = self.root .. "/" .. id
        ok, err = fs.mkdir_excl(dir)
        if ok then
            ok, err = fs.fsync_dir(self.root)
            if not ok then return fail(err, self.root) end
            local path = dir .. "/notebook.json"
            ok, err = fs.write_atomic(path, encode_doc({
                format = FORMAT, v = VERSION, id = id,
                created = floor(now_unix_s),
                abs = { round(cfg.abs_x_max), round(cfg.abs_y_max),
                        round(cfg.abs_p_max) },
                panel = { round(cfg.W), round(cfg.H), round(cfg.dpi) },
            }, META))
            if not ok then return fail(err, path) end
            return id
        elseif err ~= "EEXIST" then
            return fail(err, dir)
        end
    end
    return fail("EEXIST", self.root .. "/" .. stamp .. "-*")
end

function Store:open(id)
    if not J.is_id(id) then
        return fail("EINVAL", self.root .. "/" .. tostring(id))
    end
    local meta, err = self:_read_meta(id)
    if not meta then return nil, err end
    return setmetatable({
        fs = self.fs, id = id, dir = self.root .. "/" .. id, meta = meta,
        _seen = {},      -- [n] = the page file is known to exist
        _new = {},       -- [n] = created by us; its dir entry is unsynced
        _dirty = {},     -- [n] = appended since the last fsync
        _poisoned = {},  -- [n] = an append failed; the file may end torn
    }, Notebook)
end

--- The prefs as saved, without their "v"; {} and a reason when there are
-- none this build can read.  A file without "v" is version 1.
function Store:load_prefs()
    local fs, path = self.fs, self.root .. "/prefs.json"
    if not fs.exists(path) then return {} end
    local s, err = fs.read(path)
    if not s then return {}, (err or "EIO") .. " " .. path end
    local t = decode_doc(s, PREFS)
    if not t then return {}, "EBADMSG " .. path end
    local v = t.v or PREFS_VERSION
    if v ~= PREFS_VERSION then
        return {}, format("EPROTO %s is version %d, not %d", path, v,
                          PREFS_VERSION)
    end
    t.v = nil
    return t
end

--- Write t (the controller's prefs, without "v") at this version.
function Store:save_prefs(t)
    local ok, err = self:_ensure_root()
    if not ok then return nil, err end
    local doc = { v = PREFS_VERSION }
    for k, val in pairs(t) do doc[k] = val end
    local path = self.root .. "/prefs.json"
    ok, err = self.fs.write_atomic(path, encode_doc(doc, PREFS))
    if not ok then return fail(err, path) end
    return true
end

------------------------------------------------------------------------
-- An open notebook.
------------------------------------------------------------------------

function Notebook:page_path(n)
    return self.dir .. "/" .. J.page_name(n)
end

function Notebook:pages()
    local names, err = self.fs.listdir(self.dir)
    if not names then return fail(err, self.dir) end
    return page_numbers(names)
end

--- A page's lines, repairing a torn tail first.  A blank page (no file)
-- is {}.  The truncate is fsynced before returning, so a power cut after
-- this cannot bring the fragment back under a new record.
function Notebook:page_lines(n)
    local fs, path = self.fs, self:page_path(n)
    if not fs.exists(path) then
        -- no file, no fragment: a failed first append left nothing behind
        self._poisoned[n] = nil
        return {}, false
    end
    local s, err = fs.read(path)
    if not s then return fail(err, path) end
    local repaired = false
    local len = #s
    if len > 0 and byte(s, len) ~= 10 then
        local cut = len - 1
        while cut > 0 and byte(s, cut) ~= 10 do cut = cut - 1 end
        local ok
        ok, err = fs.truncate(path, cut)
        if not ok then return fail(err, path) end
        ok, err = fs.fsync(path)
        if not ok then return fail(err, path) end
        s, len, repaired = sub(s, 1, cut), cut, true
    end
    self._seen[n] = true
    self._poisoned[n] = nil
    local lines, k, pos = {}, 0, 1
    while pos <= len do
        local nl = find(s, "\n", pos, true)
        k = k + 1
        lines[k] = sub(s, pos, nl - 1)
        pos = nl + 1
    end
    return lines, repaired
end

--- Append one encoded record: a single write of line .. "\n", no fsync.
-- After a failed append the file may end in a fragment, so the page takes
-- no more appends until page_lines has repaired it.  An existing page
-- file this notebook has not read is refused for the same reason: an
-- earlier session may have left it torn, and only page_lines repairs.
function Notebook:append(n, line)
    local fs, path = self.fs, self:page_path(n)
    if type(line) ~= "string" or line == "" or find(line, "\n", 1, true) then
        return fail("EINVAL", path)
    end
    if self._poisoned[n] then return fail("EIO", path) end
    if not self._seen[n] then
        if fs.exists(path) then return fail("EINVAL", path) end
        self._new[n] = true
    end
    local ok, err = fs.append(path, line .. "\n")
    if not ok then
        self._poisoned[n] = true
        return fail(err, path)
    end
    self._seen[n] = true
    self._dirty[n] = true
    return true
end

--- fsync a page if it has unsynced appends, then its directory the first
-- time the file was created.  A clean page costs no syscall, so the
-- controller may call this on every leave.
function Notebook:fsync(n)
    if not self._dirty[n] then return true end
    local fs, path = self.fs, self:page_path(n)
    local ok, err = fs.fsync(path)
    if not ok then return fail(err, path) end
    self._dirty[n] = nil
    if self._new[n] then
        ok, err = fs.fsync_dir(self.dir)
        if not ok then
            -- the data is down but the file's entry may not be: keep the
            -- page dirty so the next fsync retries the directory
            self._dirty[n] = true
            return fail(err, self.dir)
        end
        self._new[n] = nil
    end
    return true
end

-- Internals for the host test: the codec over its own schemas.
J._codec = {
    schema = schema, encode_obj = encode_obj, decode_obj = decode_obj,
    RECORD = RECORD, META = META, PREFS = PREFS, MAXI = MAXI,
}

return J
