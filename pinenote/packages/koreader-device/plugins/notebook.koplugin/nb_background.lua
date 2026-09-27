-- Fixed paper in physical panel coordinates, independent of the ink journal.
-- backgrounds.conf declares which pages require paper; undeclared pages are
-- blank. P5 grayscale avoids image-decoder/scaling ambiguity. Never rescale:
-- both the paper and the journal must refer to the same physical pixels.
local BB = require("ffi/blitbuffer")
local ffi = require("ffi")
local Background = {}
Background.__index = Background

function Background.open(nb, cfg)
    local path = nb.dir .. "/backgrounds.conf"
    local text, err = nb.fs.read(path)
    if not text then
        if err == "ENOENT" then return setmetatable({ pages = {} }, Background) end
        return nil, (err or "EIO") .. " " .. path
    end
    local w, h, rest = text:match("^wilkbook%-backgrounds%-v1 (%d+) (%d+)\n(.*)$")
    if tonumber(w) ~= cfg.W or tonumber(h) ~= cfg.H or not rest
       or #rest > 8192 or rest:sub(-1) ~= "\n" then
        return nil, "invalid background manifest or panel size: " .. path
    end
    local pages = {}
    for line in rest:gmatch("([^\n]*)\n") do
        local n = tonumber(line)
        if not n or n ~= math.floor(n) or math.abs(n) > 1000000
           or tostring(n) ~= line or pages[n] then
            return nil, "invalid background page: " .. path
        end
        pages[n] = true
    end
    return setmetatable({ pages = pages, nb = nb, W = cfg.W, H = cfg.H }, Background)
end

-- nil with no error is ordinary blank paper. The caller owns a returned bb.
function Background:load(n)
    if not self.pages[n] then return nil end
    local path = self.nb.dir .. "/background-" .. n .. ".pgm"
    local text, err = self.nb.fs.read(path)
    if not text then return nil, (err or "EIO") .. " " .. path end
    local header = string.format("P5\n%d %d\n255\n", self.W, self.H)
    if text:sub(1, #header) ~= header or #text ~= #header + self.W * self.H then
        return nil, "invalid background pixels: " .. path
    end
    local bb = BB.new(self.W, self.H, BB.TYPE_BB8)
    ffi.copy(bb.data, ffi.cast("const uint8_t *", text) + #header, self.W * self.H)
    return bb
end

return Background
