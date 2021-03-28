local M = {}

local function send()
  local data = {
    vehicle_id = obj:getID(),
    throttle_input = electrics.values.throttle_input,
    brake_input = electrics.values.brake_input,
    clutch = electrics.values.clutch_input,
    parkingbrake = electrics.values.parkingbrake_input,
    steering_input = electrics.values.steering_input,
  }
  obj:queueGameEngineLua("network.send_messagepack(2, false, \'"..jsonEncode(data).."\')")
end

local function apply(data)
  local data = jsonDecode(data)
  input.event("throttle", data.throttle_input, 1)
  input.event("brake", data.brake_input, 2)
  input.event("steering", data.steering_input, 2)
  input.event("parkingbrake", data.parkingbrake, 2)
  input.event("clutch", data.clutch, 1)
end

local function kissUpdateOwnership(owned)
  if owned then return end
  hydros.enableFFB = false
  hydros.onFFBConfigChanged(nil)
end

M.send = send
M.apply = apply

M.kissUpdateOwnership = kissUpdateOwnership

return M
