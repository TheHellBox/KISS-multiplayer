local M = {}
local prev_electrics = {}
local prev_signal_electrics = {}
local last_engine_state = true
local engine_timer = 0
local ownership = false

local ignored_keys = {
  throttle = true,
  throttle_input = true,
  brake = true,
  brake_input = true,
  clutch = true,
  clutch_input = true,
  clutchRatio = true,
  parkingbrake = true,
  parkingbrake_input = true,
  steering = true,
  steering_input = true,
  regenThrottle = true,
  reverse = true,
  parking = true,
  lights = true,
  turnsignal = true,
  hazard = true,
  hazard_enabled = true,
  signal_R = true,
  signal_L = true,
  gear = true,
  gear_M = true,
  gear_A = true,
  gearIndex = true,
  exhaustFlow = true,
  engineLoad = true,
  airspeed = true,
  axle_FL = true,
  airflowspeed = true,
  watertemp = true,
  driveshaft_F = true,
  rpmspin = true,
  wheelspeed = true,
  oil = true,
  rpm = true,
  altitude = true,
  avgWheelAV = true,
  lowpressure = true,
  lowhighbeam = true,
  lowbeam = true,
  highbeam = true,
  oiltemp = true,
  rpmTacho = true,
  axle_FR = true,
  fuel_volume = true,
  driveshaft = true,
  fuel = true,
  engineThrottle = true,
  fuelCapacity = true,
  fuelVolume = true,
  turboSpin = true,
  turboRPM = true,
  turboBoost = true,
  virtualAirspeed = true,
  turboRpmRatio = true,
  lockupClutchRatio = true,
  abs = true,
  absActive = true,
  tcs = true,
  tcsActive = true,
  esc = true,
  escActive = true,
  brakelights = true,
  radiatorFanSpin = true,
  smoothShiftLogicAV = true,
  accXSmooth = true,
  accYSmooth = true,
  accZSmooth = true,
  trip = true,
  odometer = true,
  steeringUnassisted = true,
  boost = true,
  superchargerBoost = true,
  gearModeIndex = true,
  hPatternAxisX = true,
  hPatternAxisY = true,
  tirePressureControl_activeGroupPressure = true,
  reverse_wigwag_L = true,
  reverse_wigwag_R = true,
  highbeam_wigwag_L = true,
  highbeam_wigwag_R = true,
  lowhighbeam_signal_L = true,
  lowhighbeam_signal_R = true,
  brakelight_signal_L = true,
  brakelight_signal_R = true,
  isYCBrakeActive = true,
  isTCBrakeActive = true,
  isABSBrakeActive = true,
  dseWarningPulse = true,
  dseRollingOver = true,
  dseRollOverStopped = true,
  dseCrashStopped = true
}

local electrics_handlers = {}

local function ignore_key(key)
  ignored_keys[key] = true
end

local function update_engine_state()
  if ownership then return end
  if not electrics.values.engineRunning then return end
  local engine_running = electrics.values.engineRunning > 0.5
  
  -- Trigger starter to swap the engine state
  if engine_running ~= last_engine_state then
    controller.mainController.setStarter(true)
  end
end

local function updateGFX(dt)
  engine_timer = engine_timer + dt
  if engine_timer > 5 then
    update_engine_state()
    engine_timer = engine_timer - 5
  end
end

local function send()
  local diff_count = 0
  local data = {
    diff = {}
  }
  for key, value in pairs(electrics.values) do
    if not ignored_keys[key] and type(value) == 'number' then
      if prev_electrics[key] ~= value then
        data.diff[key] = value
        diff_count = diff_count + 1
      end
      prev_electrics[key] = value
    end
  end
  local data = {
    ElectricsUndefinedUpdate = {obj:getID(), data}
  }
  if diff_count > 0 then
    print("=== ELECTRICS BEING SENT ===\n" .. jsonEncode(data)) 
    obj:queueGameEngineLua("network.send_data(\'"..jsonEncode(data).."\', true)")
  end
end

local function apply_diff_signals(diff)
  local signal_left_input = diff["signal_left_input"] or prev_signal_electrics["signal_left_input"] or 0
  local signal_right_input = diff["signal_right_input"] or prev_signal_electrics["signal_right_input"] or 0
  local hazard_enabled = (signal_left_input > 0.5 and signal_right_input > 0.5)
  
  if hazard_enabled then
    electrics.set_warn_signal(1)
  else
    electrics.set_warn_signal(0)
    if signal_left_input > 0.5 then
      electrics.toggle_left_signal()
    elseif signal_right_input > 0.5 then
      electrics.toggle_right_signal()
    end
  end
  
  prev_signal_electrics["signal_left_input"] = signal_left_input
  prev_signal_electrics["signal_right_input"] = signal_right_input
end

local function set_drive_mode(electric_name, drive_mode_controller, desired_value)
  -- drive modes only allow applying them by the key, we'll cycle all of them and
  -- if it's not found it'll return to the previous state
  local currentDriveMode = drive_mode_controller.getCurrentDriveModeKey()
  while true do
    drive_mode_controller.nextDriveMode()
    if math.abs(electrics.values[electric_name] - desired_value) < 0.1 then break end
    if drive_mode_controller.getCurrentDriveModeKey() == currentDriveMode then break end
  end
end

local function apply_diff(data)
  local diff = jsonDecode(data)
  apply_diff_signals(diff)
  for k, v in pairs(diff) do
    electrics.values[k] = v
    
    local handler = electrics_handlers[k]
    if handler then handler(v) end
  end
end

local function onExtensionLoaded()
  -- Ignore powertrain electrics
  local devices = powertrain.getDevices()
  for _, device in pairs(devices) do
    if device.electricsName and device.visualShaftAngle then
      ignored_keys[device.electricsName] = true
    end
    if device.electricsThrottleName then 
      ignored_keys[device.electricsThrottleName] = true
    end
    if device.electricsThrottleFactorName then
      ignored_keys[device.electricsThrottleFactorName] = true
    end
    if device.electricsClutchRatio1Name then
      ignored_keys[device.electricsClutchRatio1Name] = true
    end
    if device.electricsClutchRatio2Name then
      ignored_keys[device.electricsClutchRatio2Name] = true
    end
  end

  for i = 0, 10 do
    ignored_keys["led"..tostring(i)] = true
  end
 
  if v.data.controller and type(v.data.controller) == 'table' then 
    for _, controller_data in pairs(v.data.controller) do
      if controller_data.fileName == "lightbar" and controller_data.modes then
        -- ignore lightbar electrics
        local modes = tableFromHeaderTable(controller_data.modes)
        for _, vm in pairs(modes) do
          local configEntries = tableFromHeaderTable(deepcopy(vm.config))
          for _, j in pairs(configEntries) do
            ignored_keys[j.electric] = true
          end 
        end
      elseif controller_data.fileName == "jato" then
        -- ignore jato fuel
        ignored_keys["jatofuel"] = true
      elseif controller_data.fileName == "beaconSpin" and controller_data.electricsName then
        -- ignore beacon spin
        ignored_keys[controller_data.electricsName] = true
      elseif controller_data.fileName == "driveModes" and controller_data.modes then
        -- register handlers for syncing drive modes
        for _, vm in pairs(controller_data.modes) do
          if vm.settings then
            for _, vs in pairs(vm.settings) do
              if vs[1] == "electricsValue"  then
                local electric = vs[2].electricsName
                local drive_mode_controller = controller.getController(controller_data.name)
                electrics_handlers[electric] = function(v) set_drive_mode(electric, drive_mode_controller, v) end
              end
            end
          end
        end
      end
    end
  end
  
  -- Ignore commonly used disp_* electrics used on vehicles with gear displays
  for k,v in pairs(electrics.values) do
    if type(k) == 'string' and k:sub(1,5) == "disp_" then
      ignored_keys[k] = true
    end
  end
  
  -- Ignore common extension/controller electrics
  if _G["4ws"] and type(_G["4ws"]) == 'table' then
    ignored_keys["4ws"] = true
  end
  
  -- Register handlers
  electrics_handlers["lights_state"] = function(v) electrics.setLightsState(v) end
  electrics_handlers["fog"] = function(v) electrics.set_fog_lights(v) end
  electrics_handlers["lightbar"] = function(v) electrics.set_lightbar_signal(v) end
  electrics_handlers["horn"] = function(v) electrics.horn(v > 0.5) end
  electrics_handlers["hasABS"] = function(v)
    if v > 0.5 then
      wheels.setABSBehavior("realistic")
    else
      wheels.setABSBehavior("off")
    end
  end
  electrics_handlers["engineRunning"] = function(v) 
    last_engine_state = v > 0.5
    update_engine_state()
    engine_timer = 0
  end
end

local function kissUpdateOwnership(owned)
  ownership = owned
end



M.send = send
M.apply = apply
M.apply_diff = apply_diff
M.ignore_key = ignore_key

M.kissUpdateOwnership = kissUpdateOwnership

M.onExtensionLoaded = onExtensionLoaded
M.updateGFX = updateGFX

return M
