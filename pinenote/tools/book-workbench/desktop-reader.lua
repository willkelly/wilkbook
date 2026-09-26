-- The desktop launcher owns this entrypoint. KOReader's SDL adapter does not
-- check a NULL renderer/texture and can otherwise run forever without showing
-- a Wayland window. Keep the failure diagnostic from the failing SDL call.
require("setupkoenv")
local ffi = require("ffi")
local util = require("ffi/util")
local load_sdl = util.loadSDL3
util.loadSDL3 = function(...)
    local lib = load_sdl(...)
    -- Device detection relies on a missing SDL library remaining falsey.
    if not lib then return nil end
    return setmetatable({}, { __index = function(symbols, name)
        local value = lib[name]
        if name == "SDL_Init" or name == "SDL_CreateWindow" or name == "SDL_CreateRenderer"
                or name == "SDL_CreateTexture" then
            local call = value
            value = function(...)
                local result = call(...)
                if result == nil or result == false then
                    error("Book Workbench desktop startup: " .. name .. ": "
                        .. ffi.string(lib.SDL_GetError()), 0)
                end
                return result
            end
        end
        -- Cache every resolved symbol: rendering and input need no per-call
        -- proxy work after their first lookup.
        rawset(symbols, name, value)
        return value
    end })
end
dofile("reader.lua")
