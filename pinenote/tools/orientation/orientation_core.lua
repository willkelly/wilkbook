-- Pure orientation state machine.  Values are SC7A20 milli-g samples.
local M = {}

M.config = {
    gravity_min = 800,
    gravity_max = 1200,
    dominant_min = 700,
    dominance_margin = 180,
    switch_margin = 100,
    stable_samples = 3,
    stable_dwell_ms = 180,
}

-- This is deliberately a table, rather than rotation arithmetic: it records
-- the hardware-calibrated PineNote physical edge -> KOReader mode contract.
M.axis_modes = {
    x_negative = 1, -- TOP edge up: raw -X
    y_positive = 2, -- LEFT edge up: raw +Y
    x_positive = 3, -- BOTTOM edge up: raw +X
    y_negative = 0, -- RIGHT edge up: raw -Y
}

local function abs(n) return n < 0 and -n or n end

function M.classify(x, y, z, cfg, committed)
    cfg = cfg or M.config
    local magnitude = math.sqrt(x * x + y * y + z * z)
    if magnitude < cfg.gravity_min or magnitude > cfg.gravity_max then
        return nil
    end
    local ax, ay = abs(x), abs(y)
    local dominant, other, mode
    if ax >= ay then
        dominant, other = ax, ay
        mode = x < 0 and M.axis_modes.x_negative or M.axis_modes.x_positive
    else
        dominant, other = ay, ax
        mode = y >= 0 and M.axis_modes.y_positive or M.axis_modes.y_negative
    end
    local required_margin = cfg.dominance_margin
    if committed ~= nil and mode ~= committed then
        required_margin = required_margin + cfg.switch_margin
    end
    if dominant < cfg.dominant_min or dominant - other < required_margin then
        return nil
    end
    return mode
end

function M.new(cfg)
    return { cfg = cfg or M.config, committed = nil, candidate = nil,
             candidate_since_ms = nil, candidate_count = 0 }
end

-- Feed one coherent XYZ scan.  Returns a newly committed mode, or nil.
function M.feed(state, x, y, z, now_ms)
    local mode = M.classify(x, y, z, state.cfg, state.committed)
    if not mode then
        state.candidate = nil
        state.candidate_since_ms = nil
        state.candidate_count = 0
        return nil
    end
    if state.committed == mode then
        state.candidate = nil
        state.candidate_since_ms = nil
        state.candidate_count = 0
        return nil
    end
    if state.candidate ~= mode then
        state.candidate = mode
        state.candidate_since_ms = now_ms
        state.candidate_count = 1
        return nil
    end
    state.candidate_count = state.candidate_count + 1
    if state.candidate_count >= state.cfg.stable_samples
       and now_ms - state.candidate_since_ms >= state.cfg.stable_dwell_ms then
        state.committed = mode
        state.candidate = nil
        state.candidate_since_ms = nil
        state.candidate_count = 0
        return mode
    end
    return nil
end

return M
