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
    mode = device.mode,
    gear_index = device.gearIndex,
  }
  obj:queueGameEngineLua("networking.send_messagepack(3, false, \'"..jsonEncode(data)"\')")
end

local function apply(data)
  local data = jsonDecode(data)
end

M.send = send
M.apply = apply
M.gearboxBehaviorChanged = gearboxBehaviorChanged

return M
