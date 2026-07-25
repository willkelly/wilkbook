-- Pure validation and decode helpers for the SC7A20 buffered scan ABI.
local M = {}

local function accel_type(value)
    return value == "le:s12/16>>4"
end

function M.layout(metadata)
    if metadata.x_index ~= "0" or metadata.y_index ~= "1"
       or metadata.z_index ~= "2" or metadata.timestamp_index ~= "3"
       or not accel_type(metadata.x_type) or not accel_type(metadata.y_type)
       or not accel_type(metadata.z_type)
       or metadata.timestamp_type ~= "le:s64/64>>0" then
        return nil
    end
    -- Three 16-bit channels occupy bytes 0..5. IIO aligns the enabled
    -- 64-bit timestamp (index 3) to byte 8, producing a 16-byte scan.
    return { x_offset = 0, y_offset = 2, z_offset = 4,
             timestamp_offset = 8, bytes = 16 }
end

function M.signed12_le(byte0, byte1)
    local raw = byte0 + byte1 * 256
    raw = math.floor(raw / 16)
    return raw >= 2048 and raw - 4096 or raw
end

function M.decode(bytes, layout)
    if #bytes ~= layout.bytes then return nil end
    local function axis(offset)
        return M.signed12_le(bytes:byte(offset + 1), bytes:byte(offset + 2))
    end
    return axis(layout.x_offset), axis(layout.y_offset), axis(layout.z_offset)
end

return M
