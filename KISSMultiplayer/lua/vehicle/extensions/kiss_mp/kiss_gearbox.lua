local M = {}

M.arcade = true

local function gearboxBehaviorChanged(behavior)
  M.arcade = behavior == "arcade"
end

local function send()
  local device = powertrain.getDevice("gearbox")
  local data = {
    vehicle_id = obj:getID(),
    arcade = M.arcade,
    lock_coef = device.lockCoef,
    mode = device.mode or "none",
    gear_index = device.gearIndex,
  }

  if device.mode then
    data.mode = device.mode
  end
  obj:queueGameEngineLua("network.send_messagepack(3, false, \'"..jsonEncode(data).."\')")
end

local function apply(data)
  local data = jsonDecode(data)
  local device = powertrain.getDevice("gearbox")
  device:setGearIndex(data[5])
  if not data[4] == "none" then
    device:setMode(data[4])
  end
end

M.send = send
M.apply = apply
M.gearboxBehaviorChanged = gearboxBehaviorChanged

return M
