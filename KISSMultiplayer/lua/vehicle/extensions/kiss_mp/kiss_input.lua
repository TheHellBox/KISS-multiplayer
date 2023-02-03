local M = {}

local function apply(data)
  local data = jsonDecode(data)
  input.event("throttle", data.throttle_input, 1)
  input.event("brake", data.brake_input, 2)
  input.event("parkingbrake", data.parkingbrake, 2)
  input.event("clutch", data.clutch, 1)
  input.event("steering", data.steering_input, 2, 0, 0)
end

local function kissUpdateOwnership(owned)
  if owned then return end
  hydros.enableFFB = false
  hydros.onFFBConfigChanged(nil)
end

M.apply = apply

M.kissUpdateOwnership = kissUpdateOwnership

return M
