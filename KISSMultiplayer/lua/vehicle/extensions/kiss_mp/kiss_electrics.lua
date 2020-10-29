local M = {}
local prev_electrics = {}
local timer = 0
local ignored_keys = {
  throttle_input = true,
  brake_input = true,
  clutch = true,
  parkingbrake = true,
  steering_input = true
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

  local diff = {}
  for key, value in pairs(electrics) do
    if not ignored_keys[key] then
      if prev_electrics[key] ~= value then
        diff[key] = value
      end
      prev_electrics[key] = value
    end
  end
  obj:queueGameEngineLua("network.send_messagepack(15, true, \'"..jsonEncode(diff).."\')")
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
