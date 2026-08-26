-- Host-only pins for the EBC live-iteration lab.  ebclib.lua is a pure
-- module, so the suite requires the SHIPPED code and drives it
-- natively; page-flip.lua's renderer is extracted verbatim (the
-- pen-suite contract).  ABI pins anchor, as always, on the
-- hardware-proven GLOBAL_REFRESH constant before trusting siblings.
--
-- Usage: luajit test-ebc-lab.lua

local failures = 0
local function report(ok, label, detail)
    if ok then
        print("PASS: " .. label)
    else
        failures = failures + 1
        print("FAIL: " .. label .. (detail and (" - " .. detail) or ""))
    end
end
local function fatal(msg)
    print("FAIL: " .. msg)
    os.exit(1)
end

package.path = "./?.lua;" .. package.path
local lib = require("ebclib")

-- ------------------------------------------------------------- ABI
report(lib.GLOBAL_REFRESH_IOCTL == 0xC0016440,
    "generator reproduces the hardware-proven GLOBAL_REFRESH 0xC0016440",
    string.format("0x%08X", lib.GLOBAL_REFRESH_IOCTL))
report(lib.MODE_IOCTL == 0xC0086444, "MODE ioctl is 0xC0086444")
report(lib.RECT_HINTS_IOCTL == 0x40106443, "RECT_HINTS ioctl is 0x40106443")
report(lib.PS_ELM_SIZE == 148, "phase-sequence element is 148 bytes")
report(lib.PS_SIZE == 14224, "phase-sequence struct is 14224 bytes")
report(lib.PHASE_SEQUENCE_IOCTL == 0x77906446,
    "PHASE_SEQUENCE ioctl is 0x77906446",
    string.format("0x%08X", lib.PHASE_SEQUENCE_IOCTL))

-- ------------------------------------------------------- rect hints
do
    local r = lib.pack_rect_hint(0x20, 100, 200, 300, 400)
    report(#r == 24, "rect_hint is 24 bytes", tostring(#r))
    report(r:byte(1) == 0x20 and r:sub(2, 8) == string.rep("\0", 7),
        "hint byte leads, 7 pad bytes follow")
    local function u32(s, off)
        local b = { s:byte(off + 1, off + 4) }
        return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
    end
    report(u32(r, 8) == 100 and u32(r, 12) == 200,
        "rect x1/y1 land at offsets 8/12")
    report(u32(r, 16) == 400 and u32(r, 20) == 600,
        "rect x2/y2 are EXCLUSIVE (x+w, y+h)")

    local h = lib.pack_rect_hints_header(true, 160, 3)
    report(#h == 16, "rect_hints header is 16 bytes")
    report(h:byte(1) == 1 and h:byte(2) == 160,
        "set_default_hint and the hint lead")
    report(u32(h, 4) == 3, "num_rects at offset 4")
    report(h:sub(9) == string.rep("\0", 8),
        "the pointer field is zero until the caller patches it")
end

-- --------------------------------------------------- phase sequence
do
    local blob, err = lib.pack_phase_sequence({
        do_init = true, gc_target = 15, temperature = 8, delay_ms = 7,
        elms = { { delay_ms = 12, num_frames = 6, regions = {
            { x = 10, y = 20, w = 30, h = 40, phase = 0x55 } } } },
    })
    if not blob then fatal("pack_phase_sequence failed: " .. tostring(err)) end
    report(#blob == lib.PS_SIZE, "packed program is exactly PS_SIZE")
    report(blob:byte(1) == 1, "num_seqs counts the elements")
    report(blob:byte(2) == 1 and blob:byte(3) == 0,
        "do_init set, do_gc16 clear")
    report(blob:byte(4) == 15 and blob:byte(5) == 1 and blob:byte(6) == 8,
        "gc_target, do_force_temperature, force_temperature in order")
    local function u32(off)
        local b = { blob:byte(off + 1, off + 4) }
        return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216
    end
    report(u32(12) == 7, "header delay_ms at offset 12")
    report(u32(16) == 12, "element delay_ms at offset 16")
    report(blob:byte(21) == 6, "element num_frames follows")
    report(u32(24) == 1, "element num_regions at offset 24")
    report(u32(28) == 10 and u32(32) == 20 and u32(36) == 40 and u32(40) == 60,
        "region rect packs exclusive x2/y2")
    report(blob:byte(16 + 140 + 1) == 0x55,
        "phase byte lands after the 8-rect block")
    report(blob:sub(16 + 148 + 1) == string.rep("\0", 95 * 148),
        "the 95 unused elements are zero")

    local too_many = {}
    for i = 1, 97 do too_many[i] = { regions = { { x=0,y=0,w=1,h=1,phase=0 } } } end
    report(select(2, lib.pack_phase_sequence({ elms = too_many })) ~= nil,
        "97 elements are refused")
    local fat = { { regions = {} } }
    for i = 1, 9 do fat[1].regions[i] = { x=0,y=0,w=1,h=1,phase=0 } end
    report(select(2, lib.pack_phase_sequence({ elms = fat })) ~= nil,
        "9 regions in one element are refused")
end

-- ---------------------------------------------------------- discovery
do
    local root = "build/fake"
    os.execute("rm -rf " .. root .. " && mkdir -p " .. root
               .. "/class/drm/card0/device " .. root .. "/class/drm/card1/device "
               .. root .. "/class/graphics/fb0")
    local function put(rel, v)
        local f = io.open(root .. rel, "w"); f:write(v); f:close()
    end
    put("/class/drm/card0/device/uevent", "DRIVER=panfrost\n")
    put("/class/drm/card1/device/uevent", "DRIVER=rockchip-ebc\n")
    report(lib.find_ebc_card(root) == 1, "EBC resolved behind panfrost card0")
    put("/class/graphics/fb0/virtual_size", "1872,1404\n")
    put("/class/graphics/fb0/stride", "3744\n")
    put("/class/graphics/fb0/bits_per_pixel", "16\n")
    local w, h, s, b = lib.fb_geometry(root)
    report(w == 1872 and h == 1404 and s == 3744 and b == 2,
        "fb geometry reads the direct driver's RGB565")
    put("/interrupts",
        " 99:  12  34  0  0  GICv3  35 Level  fdec0000.ebc\n")
    report(lib.ebc_irq_count(root) == 12 + 34 + 0 + 0 + 35,
        "EBC irq line sums every bare numeric token ('99:' is not one; the hwirq 35 is a constant offset)")
    report(lib.ebc_irq_count(root .. "/nope") == nil,
        "absent interrupts file yields nil")
    os.execute("rm -rf " .. root)
end

-- -------------------------------------------- page-flip's renderer
do
    local lines = {}
    for line in io.lines("page-flip.lua") do lines[#lines + 1] = line end
    local function extract(name)
        local first
        for i, l in ipairs(lines) do
            if l:match("^local function " .. name .. "%(") then first = i break end
        end
        if not first then fatal("no local function " .. name) end
        for i = first + 1, #lines do
            if lines[i] == "end" then
                return table.concat(lines, "\n", first, i)
            end
        end
        fatal(name .. " never closes")
    end
    local env = { math = math, string = string, table = table,
                  ipairs = ipairs, pairs = pairs }
    local src = extract("lcg") .. "\n" .. extract("render_page")
    local chunk = loadstring(src .. "\nreturn render_page", "@extracted")
    if not chunk then fatal("extracted renderer does not compile") end
    setfenv(chunk, env)
    local render = chunk()

    local geom = { w = 1872, h = 1404, stride = 3744, bypp = 2 }
    local a1 = render(1, geom, 60, 28)
    local a2 = render(1, geom, 60, 28)
    local b1 = render(2, geom, 60, 28)
    local function fingerprint(rows)
        local n, sum = 0, 0
        for y, rs in pairs(rows) do
            for _, s in ipairs(rs) do n = n + 1; sum = sum + y + s[1] + s[2] end
        end
        return n, sum
    end
    local na1, sa1 = fingerprint(a1)
    local na2, sa2 = fingerprint(a2)
    local nb1, sb1 = fingerprint(b1)
    report(na1 > 0, "page renders ink", tostring(na1))
    report(na1 == na2 and sa1 == sa2,
        "rendering is deterministic (A/B captures stay comparable)")
    report(not (na1 == nb1 and sa1 == sb1),
        "page 1 and page 2 differ (a flip has damage)")
    local inside = true
    for y, rs in pairs(a1) do
        if y < 60 or y >= 1404 - 60 then inside = false end
        for _, s in ipairs(rs) do
            if s[1] < 60 or s[2] > 1872 - 60 then inside = false end
        end
    end
    report(inside, "ink respects the margins")
end

-- ------------------------------------------------------- structural
do
    local function slurp(p)
        local f = io.open(p, "r"); local s = f:read("*a"); f:close(); return s
    end
    for _, p in ipairs({ "ebclib.lua", "rect-hints.lua", "phase-seq.lua",
                         "page-flip.lua", "wipe-flip.lua", "frame-clock.lua" }) do
        report(not slurp(p):match("/dev/dri/card%d"),
            p .. " carries no DRM card-index literal")
    end
    report(slurp("ebclib.lua"):find("DRIVER=rockchip-ebc", 1, true) ~= nil,
        "ebclib resolves the card by driver name")
    local swap = slurp("clut-swap.sh")
    report(swap:find("CLUT0002", 1, true) ~= nil,
        "clut-swap refuses a table without the CLUT magic")
    report(swap:find("unbind", 1, true) ~= nil
           and swap:find("/bind", 1, true) ~= nil,
        "clut-swap drives the unbind/bind cycle")
    report(swap:find("herd stop reader%-session") ~= nil,
        "clut-swap stops the reader before unbinding")
end

for _, p in ipairs({ "ebclib.lua", "rect-hints.lua", "phase-seq.lua",
                     "page-flip.lua", "wipe-flip.lua", "frame-clock.lua" }) do
    report(loadfile(p) ~= nil, p .. " compiles")
end

print(failures == 0 and "ebc-lab: all checks passed"
                    or ("ebc-lab: " .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
