local M = {}

local function send()
  local data = {
    vehicle_id = obj:getID(),
    throttle_input = electrics.values.throttle_input,
    brake_input = electrics.values.brake_input,
    clutch = electrics.values.clutch,
    parkingbrake = electrics.values.parkingbrake,
    steering_input = electrics.values.steering_input,
    horn = electrics.values.horn,
    toggle_right_signal = electrics.values.signal_right_input,
    toggle_left_signal = electrics.values.signal_left_input,
    toggle_lights = electrics.values.lights,
  }
  obj:queueGameEngineLua("network.send_messagepack(2, false, \'"..jsonEncode(data).."\')")
end

local function apply(data)
  local data = jsonDecode(data)
  input.event("throttle", data[2], 1)
  input.event("brake", data[3], 2)
  input.event("steering", data[6], 2)
  input.event("parkingbrake", data[5], 2)
  input.event("clutch", data[4], 1)
end

M.send = send
M.apply = apply

return M
