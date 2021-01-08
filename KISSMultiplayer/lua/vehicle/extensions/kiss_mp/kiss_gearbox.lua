local M = {}
M.arcade = true

local gearbox = nil
local gearbox_is_dct = false
local gearbox_is_manual = false

local function gearboxBehaviorChanged(behavior)
  M.arcade = behavior == "arcade"
end

local function set_gear_indices(indices)
  if gearbox_is_dct then
    gearbox:setGearIndex1(indices[1])
    gearbox:setGearIndex2(indices[2])
  else
    gearbox:setGearIndex(indices[1])
  end
end

local function get_gear_indices()
  if gearbox_is_dct then
    return {gearbox.gearIndex1, gearbox.gearIndex2}
  else
    return {gearbox.gearIndex, 0}
  end
end

local function send()
  if not gearbox then return end
  
  local data = {
    vehicle_id = obj:getID(),
    arcade = M.arcade,
    lock_coef = gearbox.lockCoef,
    mode = gearbox.mode or "none",
    gear_indices = get_gear_indices(),
  }
  obj:queueGameEngineLua("network.send_messagepack(3, false, \'"..jsonEncode(data).."\')")
end

local function apply(data)
  if not gearbox then return end
  
  local data = jsonDecode(data)
  set_gear_indices(data[5])
  if not gearbox_is_manual and data[4] ~= "none" then
    gearbox:setMode(data[4])
  end
end

local function kissInit()
  gearbox = powertrain.getDevice("gearbox")
  
  -- Search for a gearbox if one wasn't found
  if not gearbox then
    local devices = powertrain.getDevices()
    for _, device in pairs(devices) do
      if device.deviceCategories.gearbox and gearbox == nil then
        gearbox = device
      end
    end
  end
  if not gearbox then return end
  
  -- Reject CVT gearboxes because they don't have gears
  if gearbox.type == "cvtGearbox" then 
    gearbox = nil
    return
  end
  
  gearbox_is_dct = gearbox.type == "dctGearbox"
  gearbox_is_manual = gearbox.type == "manualGearbox" 
end

local function kissUpdateOwnership(owned)
  if owned then return end
  if not gearbox then return end
  if gearbox.type == "manualGearbox" then
    gearbox.gearDamageThreshold = math.huge
  end
end

M.send = send
M.apply = apply
M.gearboxBehaviorChanged = gearboxBehaviorChanged

M.kissInit = kissInit
M.kissUpdateOwnership = kissUpdateOwnership

return M
