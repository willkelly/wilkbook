local root = assert(arg[1], "repository root required")
package.path = root .. "/pinenote/tools/orientation/?.lua;" .. package.path
local core = require("orientation_core")
local scan = require("orientation_scan")
local fail = 0
local function ok(value, label)
    print(string.format("%s: %s", value and "PASS" or "FAIL", label))
    if not value then fail = fail + 1 end
end
local function mode(x, y, z) return core.classify(x, y, z) end
local layout = scan.layout{
    x_index = "0", y_index = "1", z_index = "2", timestamp_index = "3",
    x_type = "le:s12/16>>4", y_type = "le:s12/16>>4", z_type = "le:s12/16>>4",
    timestamp_type = "le:s64/64>>0",
}
ok(layout and layout.bytes == 16 and layout.timestamp_offset == 8,
   "timestamp-enabled SC7A20 layout is exactly 16 bytes")
ok(scan.layout{ x_index = "0", y_index = "1", z_index = "2", timestamp_index = "3",
                x_type = "le:s12/16>>4", y_type = "le:s12/16>>4", z_type = "le:s12/16>>4",
                timestamp_type = "le:s64/64>>1" } == nil,
   "scan metadata rejects incompatible timestamp layout")
ok(scan.signed12_le(0x10, 0x00) == 1 and scan.signed12_le(0xf0, 0xff) == -1,
   "s12 little-endian positive and negative decode")
local bytes = string.char(0x10, 0x00, 0xf0, 0xff, 0x00, 0x80, 0, 0,
                          1, 0, 0, 0, 0, 0, 0, 0)
local x, y, z = scan.decode(bytes, layout)
ok(x == 1 and y == -1 and z == -2048 and scan.decode(bytes:sub(1, 6), layout) == nil,
   "decode requires one complete timestamp-enabled scan")
ok(mode(-993, 0, 0) == 1 and mode(0, -988, 0) == 0
   and mode(1050, 0, 0) == 3 and mode(0, 1004, 0) == 2,
   "calibrated four-edge mapping")
ok(mode(0, 40, -960) == nil, "flat sample rejected")
ok(mode(720, 680, 0) == nil and mode(700, 0, 0) == nil,
   "diagonal and boundary noise rejected")
ok(mode(0, 0, 300) == nil and mode(-1700, 0, 0) == nil,
   "magnitude sanity rejects non-gravity samples")
local cfg = { gravity_min = 800, gravity_max = 1200, dominant_min = 700,
              dominance_margin = 180, switch_margin = 100,
              stable_samples = 3, stable_dwell_ms = 180 }
ok(core.classify(550, 800, 0, cfg, 1) == nil
   and core.classify(550, 800, 0, cfg, 2) == 2,
   "switch hysteresis rejects a margin accepted for the committed mode")
local reset = core.new(cfg)
ok(core.feed(reset, -1000, 0, 0, 0) == nil
   and core.feed(reset, 0, 40, -960, 100) == nil
   and core.feed(reset, -1000, 0, 0, 200) == nil
   and core.feed(reset, -1000, 0, 0, 300) == nil
   and core.feed(reset, -1000, 0, 0, 380) == 1,
   "ambiguous sample resets candidate dwell")
local s = core.new(cfg)
ok(core.feed(s, -1000, 0, 0, 0) == nil
   and core.feed(s, -1000, 0, 0, 100) == nil
   and core.feed(s, -1000, 0, 0, 180) == 1
   and core.feed(s, -1000, 0, 0, 400) == nil,
   "debounce commits once and suppresses duplicates")
ok(core.feed(s, 0, 900, 0, 500) == nil
   and core.feed(s, 0, 900, 0, 600) == nil
   and core.feed(s, 0, 900, 0, 680) == 2,
   "new stable orientation commits after dwell")
if fail == 0 then print("RESULT: ok") else print("RESULT: failed"); os.exit(1) end
