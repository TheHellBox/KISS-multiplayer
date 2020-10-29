local M = {}
local prev_electrics = {}
local timer = 0
local ignored_keys = {
  throttle = true,
  throttle_input = true,
  brake_input = true,
  clutch = true,
  parkingbrake = true,
  steering_input = true,
  exhaustFlow = true,
  engineLoad = true,
  airspeed = true,
  axle_FL = true,
  airflowspeed = true,
  watertemp = true,
  driveshaft_F = true,
  rpmspin = true,
  wheelspeed = true,
  rpm = true,
  altitude = true,
  avgWheelAV = true,
  oiltemp = true,
  rpmTacho = true,
  axle_FR = true,
  fuel_volume = true,
  driveshaft = true,
  fuel = true,
  engineThrottle = true,
  fuelVolume = true,
  turboSpin = true,
  turboRPM = true,
  virtualAirspeed = true,
  turboRpmRatio = true,
  tcs = true,
  tcsActive = true,
  esc = true,
  escActive = true,
  brakelights = true
}

local function send()
  local data = {
    vehicle_id = obj:getID(),
    throttle_input = electrics.values.throttle_input,
    brake_input = electrics.values.brake_input,
    clutch = electrics.values.clutch,
    parkingbrake = electrics.values.parkingbrake,
    steering_input = electrics.values.steering_input,
  }
  obj:queueGameEngineLua("network.send_messagepack(2, false, \'"..jsonEncode(data).."\')")

  local data = {
    vehicle_id = obj:getID(),
    diff = {}
  }
  for key, value in pairs(electrics.values) do
    if not ignored_keys[key] then
      if prev_electrics[key] ~= value then
        data.diff[key] = value
      end
      prev_electrics[key] = value
    end
  end
  obj:queueGameEngineLua("network.send_messagepack(15, true, \'"..jsonEncode(data).."\')")
end

local function apply(data)
  local data = jsonDecode(data)
  input.event("throttle", data[2], 1)
  input.event("brake", data[3], 2)
  input.event("steering", data[6], 2)
  input.event("parkingbrake", data[5], 2)
  input.event("clutch", data[4], 1)
end

local function apply_diff(data)
  local diff = jsonDecode(data)
  for k, v in pairs(diff) do
    electrics.values[k] = v
    if k == "hazard_enabled" then
      electrics.set_warn_signal(v)
    elseif k == "signal_left_input" then
      electrics.toggle_left_signal()
    elseif k == "signal_right_input" then
      electrics.toggle_right_signal()
    elseif k == "lights_state" then
      electrics.setLightsState(v)
    elseif k == "fog" then
      electrics.set_fog_lights(v)
    elseif k == "lightbar" then
      electrics.set_lightbar_signal(v)
    elseif k == "engineRunning" then
      controller.mainController.setStarter(v > 0.5)
    elseif k == "horn" then
      electrics.horn(v > 0.5)
    end
  end
end

M.send = send
M.apply = apply
M.apply_diff = apply_diff

return M
