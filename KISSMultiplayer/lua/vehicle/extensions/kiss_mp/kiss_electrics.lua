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
    toggle_right_signal = electrics.values.toggle_right_signal,
    toggle_left_signal = electrics.values.toggle_left_signal,
    toggle_lights = electrics.values.toggle_lights,
  }
  obj:queueGameEngineLua("networking.send_messagepack(2, false, \'"..jsonEncode(data)"\')")
end

local function apply(data)
  local data = jsonDecode(data)
  input.event("throttle", data.throttle_input, 1)
  input.event("brake", data.brake_input, 2)
  input.event("steering", data.steering_input, 2)
  input.event("parkingbrake", data.steering_input, 2)
  input.event("clutch", data.clutch_input, 1)
end

M.send = send
M.apply = apply

return M
