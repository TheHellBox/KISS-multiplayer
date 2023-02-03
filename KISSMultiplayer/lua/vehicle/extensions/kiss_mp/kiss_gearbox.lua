local M = {}

local mainController = nil
local gearbox = nil

local gearbox_is_sequential = false
local vehicle_is_electric = false
local gearbox_is_manual = false

local last_requseted_gear = nil
local sequential_lock = false
local ownership = false
local ownership_known = false
local cooldown_timer = 0

local function set_gear_indices(indices)
  if mainController and cooldown_timer <= 0 then
    local index = indices[1]
    local canShift = true
    
    -- there's a neutralRejectTimer that will lock sequentials into neutral if we try it more than once
    -- possibly a game bug
    if sequential_lock then
      canShift = false
    elseif index == 0 and gearbox_is_sequential then
      sequential_lock = true
    end
    
    if canShift then
      mainController.shiftToGearIndex(index, true) -- true for ignoring sequential bounds
      last_requseted_gear = index
    end
  end
end

local function get_gear_indices()
  local index = electrics.values.gearIndex
  
  -- convert gearIndex to values that shiftToGearIndex accepts
  if index == nil then index = 0 end
  if not gearbox_is_sequential and not gearbox_is_manual then
    if type(electrics.values.gear) == 'string' and string.sub(electrics.values.gear, 1, 1) == 'M' then
      index = 6 -- M1 is the best we can do
    elseif electrics.values.gear == "P" then     
      index = 1 -- park
    elseif index >= 1 then
      index = 2 -- drive
    end
  end
  
  return {index, 0}
end

local function get_gearbox_data()
  local data = {
    vehicle_id = obj:getID(),
    lock_coef = gearbox and gearbox.lockCoef or 0,
    mode = gearbox and gearbox.mode or "none",
    gear_indices = get_gear_indices(),
    arcade = false
  }
  return data
end

local function apply(data)
  local data = jsonDecode(data)
  set_gear_indices(data.gear_indices)
end

local function updateGFX(dt)
  if not ownership_known or ownership then return end
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if sequential_lock and electrics.values.gearIndex == 0 then
    sequential_lock = false
  end
  if gearbox_is_manual and last_requseted_gear ~= 0 and electrics.values.gearIndex == 0 then
    electrics.values.clutchOverride = 1
  else
    electrics.values.clutchOverride = nil
  end  
end

local function onReset()
  cooldown_timer = 0.2
  sequential_lock = false
end

local function onExtensionLoaded()
  mainController = controller.mainController
  vehicle_is_electric = tableSize(powertrain.getDevicesByType("electricMotor")) > 0
  gearbox = powertrain.getDevice("gearbox")
  
  -- Search for a gearbox if one wasn't found
  if not gearbox and not vehicle_is_electric then
    local devices = powertrain.getDevices()
    for _, device in pairs(devices) do
      if device.deviceCategories.gearbox and gearbox == nil then
        gearbox = device
      end
    end
  end
  
  if gearbox then
    gearbox_is_manual = gearbox.type == "manualGearbox"
    gearbox_is_sequential = gearbox.type == "sequentialGearbox"
  end
end

local function kissUpdateOwnership(owned)
  ownership = owned
  ownership_known = true
  if owned then return end
  if gearbox and gearbox_is_manual then
    gearbox.gearDamageThreshold = math.huge
  end
end

M.send = send
M.apply = apply
M.get_gearbox_data = get_gearbox_data
M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX
M.onReset = onReset
M.kissUpdateOwnership = kissUpdateOwnership

return M
