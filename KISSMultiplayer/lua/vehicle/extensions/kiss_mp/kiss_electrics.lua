local M = {}

function send()
  local data = {
    vehicle_id = electrics.values.clutch,
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

return M
