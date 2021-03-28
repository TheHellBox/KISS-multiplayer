local M = {}

local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

local timer = 0
local generation = 0
local meta_timer = 0
local vehicle_buffer = {}
local colors_buffer = {}
local plates_buffer = {}
local first_vehicle = true

M.loading_map = false
M.id_map = {}
M.server_ids = {}
M.ownership = {}
M.vehicle_updates_buffer = {}
M.packet_gen_buffer = {}
M.is_network_session = false
M.delay_spawns = false

local function get_current_time()
  local date = os.date("*t", os.time() + network.connection.time_offset)
  date.sec = 0
  date.min = 0
  return (network.socket.gettime() + network.connection.time_offset  - os.time(date))
end

local function enable_spawning(enabled)
  local jsCommand = 'angular.element(document.body).injector().get("VehicleSelectConfig").configs.default.hide = {"spawnNew":' .. tostring(not enabled) .. '}'
  be:queueJS(jsCommand)
end

local function color_eq(a, b)
  return (a[1] == b[1]) and (a[2] == b[2]) and {a[3] == b[3]} and {a[4] == b[4]}
end

local function colors_eq(a, b)
  return color_eq(a[1], b[1]) and color_eq(a[2], b[2]) and color_eq(a[3], b[3])
end

local function send_vehicle_update(obj)
  if not kisstransform.local_transforms[obj:getID()] then return end
  local t = kisstransform.local_transforms[obj:getID()]
  local position = obj:getPosition()
  local velocity = obj:getVelocity()
  local result = {
    transform = {
      position = {position.x, position.y, position.z},
      rotation = t.rotation,
      velocity = {velocity.x, velocity.y, velocity.z},
      angular_velocity = {t.vel_pitch, t.vel_roll, t.vel_yaw}
    },
    electrics = {
      throttle_input = 0,
      brake_input = 0,
      clutch = 0,
      parkingbrake = 0,
      steering_input = 0
    },
    undefined_electrics = {
      diff = {}
    },
    gearbox = {
      arcade = false,
      lock_coef = 0,
      mode = nil,
      gear_indices = {0, 0}
    },
    vehicle_id = obj:getID(),
    generation = generation,
    sent_at = get_current_time()
  }
  generation = generation + 1
  network.send_data(
    {
      VehicleUpdate = result
    },
    false
  )
end

local function send_vehicle_meta_updates()
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      local changed = false
      local id = vehicle:getID()
      
      local color = vehicle.color
      local palete_0 = vehicle.colorPalette0
      local palete_1 = vehicle.colorPalette1
      local plate = vehicle.licenseText
      local colors = {
        {color.x, color.y, color.z, color.w},
        {palete_0.x, palete_0.y, palete_0.z, palete_0.w},
        {palete_1.x, palete_1.y, palete_1.z, palete_1.w}
      }
      
      if plates_buffer[id] then
        changed = changed or plates_buffer[id] ~= plate
      end
      plates_buffer[id] = plate
      
      if colors_buffer[id] then
        changed = changed or not colors_eq(colors, colors_buffer[id])
      end
      colors_buffer[id] = colors
      
      if changed then
        local data = {
          VehicleMetaUpdate = {
            id,
            plate,
            colors
          }
        }
        network.send_data(data, true)
      end
    end
  end
end

local function update_ownership_limits()
    local owned_vehicle_count = 0
    for _, _ in pairs(M.ownership) do
      owned_vehicle_count = owned_vehicle_count + 1
    end
    if owned_vehicle_count >= network.connection.server_info.max_vehicles_per_client then
      enable_spawning(false)
    else
      enable_spawning(true)
    end
end

local function send_vehicle_config(vehicle_id)
  local vehicle = be:getObjectByID(vehicle_id)
  if vehicle then
    vehicle:queueLuaCommand("obj:queueGameEngineLua(\"vehiclemanager.send_vehicle_config_inner("..vehicle_id..", '\"..jsonEncode(v.config)..\"')\")")
  end
end

local function send_vehicle_config_inner(id, parts_config)
  for k, v in pairs(M.id_map) do
    if v == id and not M.ownership[id] then return end
  end
  local vehicle = be:getObjectByID(id)
  local parts_config = parts_config
  local color = vehicle.color
  local palete_0 = vehicle.colorPalette0
  local palete_1 = vehicle.colorPalette1
  local plate = vehicle.licenseText
  local position = vehicle:getPosition()
  local rotation = vehicle:getRotation()

  local vehicle_data = {}
  vehicle_data.parts_config = parts_config
  vehicle_data.in_game_id = id
  vehicle_data.color = {color.x, color.y, color.z, color.w}
  vehicle_data.palete_0 = {palete_0.x, palete_0.y, palete_0.z, palete_0.w}
  vehicle_data.palete_1 = {palete_1.x, palete_1.y, palete_1.z, palete_1.w}
  vehicle_data.plate = plate
  vehicle_data.name = vehicle:getJBeamFilename()
  vehicle_data.position = {position.x, position.y, position.z}
  vehicle_data.rotation = {rotation.x, rotation.y, rotation.z, rotation.w}
  vehicle_data.server_id = 0
  vehicle_data.owner = 0
  network.send_data(
    {
      VehicleData = vehicle_data
    },
    true
  )
end

local function spawn_vehicle(data)
  if M.loading_map or M.delay_spawns then
    vehicle_buffer[data.server_id] = data
    return
  end
  if data.owner == network.get_client_id() then
    print("Vehicle belongs to local client, setting ownership")
    M.id_map[data.server_id] = data.in_game_id
    M.ownership[data.in_game_id] = data.server_id
    M.server_ids[data.in_game_id] = data.server_id
    update_ownership_limits()
    be:getObjectByID(data.in_game_id):queueLuaCommand("extensions.hook('kissUpdateOwnership', true)")
    return
  end
  if M.id_map[data.server_id] then return end
  local current_vehicle = be:getPlayerVehicle(0)
  local parts_config = jsonDecode(data.parts_config)
  local c = data.color
  local plate = data.plate
  local cp0 = data.palete_0
  local cp1 = data.palete_1
  local name = data.name
  print("Attempt to spawn vehicle "..name)
  local spawned = spawn.spawnVehicle(
    name,
    serialize(parts_config),
    vec3(data.position),
    quat(data.rotation),
    ColorF(c[1],c[2],c[3],c[4]),
    ColorF(cp0[1],cp0[2],cp0[3],cp0[4]),
    ColorF(cp1[1],cp1[2],cp1[3],cp1[4])
  )
  if not spawned then return end
  if plate ~= nil then
    extensions.core_vehicles.setPlateText(plate, spawned:getID())
  end
  M.id_map[data.server_id] = spawned:getID()
  M.server_ids[spawned:getID()] = data.server_id
  if current_vehicle then be:enterVehicle(0, current_vehicle) end
  spawned:queueLuaCommand("extensions.hook('kissUpdateOwnership', false)")
end

local function onUpdate(dt)
  if not network.connection.connected then return end

  -- Track color and plate changes
  meta_timer = meta_timer + dt
  if meta_timer >= 1 then
    send_vehicle_meta_updates()
    meta_timer = meta_timer - 1
  end

  local tick_time = (1/network.connection.tickrate)
  if timer <  tick_time then
    timer = timer + dt
  else
    timer = timer - tick_time
    for i, v in pairs(vehiclemanager.ownership) do
      local vehicle = be:getObjectByID(i)
      if vehicle then
        send_vehicle_update(vehicle)
        vehicle:queueLuaCommand("kiss_input.send()")
        vehicle:queueLuaCommand("kiss_electrics.send()")
        vehicle:queueLuaCommand("kiss_gearbox.send()")
      end
    end
  end

  for k, v in pairs(M.id_map) do
    if not M.ownership[v] then
      local vehicle = be:getObjectByID(v)
      if vehicle then
        vehicle:queueLuaCommand("kiss_vehicle.update_eligible_nodes()")
      end
    end
  end

  for id, updates in pairs(M.vehicle_updates_buffer) do
    local vehicle = be:getObjectByID(id)
    if vehicle then
      if updates.input then
        vehicle:queueLuaCommand("kiss_input.apply(\'"..jsonEncode(updates.input).."\')")
      end
      if updates.gearbox then
        vehicle:queueLuaCommand("kiss_gearbox.apply(\'"..jsonEncode(updates.gearbox).."\')")
      end
    end
  end
end

local function update_vehicle(data)
  local id = M.id_map[data.vehicle_id]
  if M.ownership[id] then return end
  if data.generation <= (M.packet_gen_buffer[id] or -1) then return end
  M.packet_gen_buffer[id] = data.generation
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end

  kisstransform.update_vehicle_transform(data)
  vehicle:queueLuaCommand("kiss_input.apply(\'"..jsonEncode(data.electrics).."\')")
  vehicle:queueLuaCommand("kiss_gearbox.apply(\'"..jsonEncode(data.gearbox).."\')")
end

local function remove_vehicle(data)
  local id = data
  local local_id = M.id_map[id] or -1
  local vehicle = be:getObjectByID(local_id)
  if vehicle then
    commands.setFreeCamera()
    vehicle:delete()
    if commands.isFreeCamera(player) then commands.setGameCamera() end
    M.id_map[id] = nil
    M.ownership[local_id] = nil
    M.vehicle_updates_buffer[local_id] = nil
    kisstransform.received_transforms[local_id] = nil
    update_ownership_limits()
  else
    vehicle_buffer[id] = nil
  end
end

local function reset_vehicle(data)
  local id = data
  id = M.id_map[id] or -1
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
  local position = vehicle:getPosition()
  if vehicle then
    vehicle:reset()
    if kisstransform.local_transforms[id] then
      local rotation = kisstransform.local_transforms[id].rotation
      vehicle:setPositionRotation(
        position.x,
        position.y,
        position.z,
        rotation[1],
        rotation[2],
        rotation[3],
        rotation[4]
      )
    end
  end
end

local function update_vehicle_meta(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
  local plate = data[2]
  local colors = {
    data[3][1],
    data[3][2],
    data[3][3]
  }

  -- Apply plate
  if plate ~= nil then
    extensions.core_vehicles.setPlateText(plate, id)
  end

  -- Apply colors
  local vd = extensions.core_vehicle_manager.getVehicleData(id)
  if not vd or not vd.config or not vd.config.colors then return end
  vd.config.colors = colors
  extensions.core_vehicle_manager.liveUpdateVehicleColors(id, vehicle)
end

local function electrics_diff_update(data)
  local id = M.id_map[data[1] or -1]
  if id and not M.ownership[id] then
    local vehicle = be:getObjectByID(id)
    if not vehicle then return end
    data = jsonEncode(data[2])
    vehicle:queueLuaCommand("kiss_electrics.apply_diff(\'"..data.."\')")
  end
end

local function attach_coupler_inner(data)
  data.obj_a = M.server_ids[data.obj_a]
  data.obj_b = M.server_ids[data.obj_b]
  network.send_data(
    {
      CouplerAttached = data
    },
    true
  )
end

local function detach_coupler_inner(data)
  data.obj_a = M.server_ids[data.obj_a]
  data.obj_b = M.server_ids[data.obj_b]
  network.send_data(
    {
      CouplerDetached = data
    },
    true
  )
end

local function attach_coupler(data)
  local obj_a = M.id_map[data.obj_a]
  local obj_b = M.id_map[data.obj_b]
  if obj_a and obj_b then
    if M.ownership[obj_a] then return end
    local vehicle = be:getObjectByID(obj_a)
    local vehicle_b = be:getObjectByID(obj_b)
    if not vehicle then return end
    if not vehicle_b then return end
    if vec3(vehicle:getPosition()):distance(vec3(vehicle_b:getPosition())) > 15 then return end
    local node_a_pos = vec3(vehicle:getPosition()) + vec3(vehicle:getNodePosition(data[3]))
    local node_b_pos = vec3(vehicle_b:getPosition()) + vec3(vehicle_b:getNodePosition(data[4]))
    local pos = vec3(vehicle_b:getPosition()) + (node_a_pos - node_b_pos)
    vehicle_b:setPosition(Point3F(pos.x, pos.y, pos.z))
    vehicle_b:queueLuaCommand("kiss_couplers.attach_coupler("..data.node_b_id..")")
    onCouplerAttached(obj_a, obj_b, data.node_a_id, data.node_b_id)
  end
end

local function detach_coupler(data)
  local obj_a = M.id_map[data.obj_a]
  local obj_b = M.id_map[data.obj_b]
  if obj_a and obj_b then
    if M.ownership[obj_a] then return end
    local vehicle = be:getObjectByID(obj_a)
    local vehicle_b = be:getObjectByID(obj_b)
    if not vehicle then return end
    if not vehicle_b then return end
    if vec3(vehicle:getPosition()):distance(vec3(vehicle_b:getPosition())) > 15 then return end
    vehicle:queueLuaCommand("kiss_couplers.detach_coupler("..data.node_a_id..")")
    onCouplerDetached(obj_a, obj_b, data.node_a_id, data.node_b_id)
  end
end

local function onVehicleSpawned(id)
  -- FIXME: Bring back
  --if not network.connection.connected then return end
  local vehicle = be:getObjectByID(id)
  local position = vehicle:getPosition()
  if first_vehicle then
    vehicle:setPosition(Point3F(position.x + math.random(-5, 5), position.y + math.random(-5, 5), position.z))
    vehicle:queueLuaCommand("recovery.saveHome()")
    first_vehicle = false
  end
  vehicle:queueLuaCommand("extensions.addModulePath('lua/vehicle/extensions/kiss_mp')")
  vehicle:queueLuaCommand("extensions.loadModulesInDirectory('lua/vehicle/extensions/kiss_mp')")
  vehicle:queueLuaCommand("extensions.hook('kissInit')")
  send_vehicle_config(id)
end

local function onVehicleDestroyed(id)
  if not network.connection.connected then return end
  if M.ownership[id] then
    M.id_map[M.ownership[id]] = nil
    M.ownership[id] = nil
    network.send_data(
      {
        RemoveVehicle = id,
      },
      true
    )
    update_ownership_limits()
  end
end

local function onVehicleResetted(id)
  if not network.connection.connected then return end
  if M.ownership[id] then
    network.send_data(
      {
        ResetVehicle = id,
      },
      true
    )
  end
end

local function onVehicleSwitched(_id, new_id)
  if M.ownership[new_id] then
    network.send_data(
      {
        VehicleSwitched = new_id,
      },
      true
    )
  end
end

local function onMissionLoaded(mission)
  M.is_network_session = network.connection.connected
  if not network.connection.connected then return end
  if mission:lower() ~= network.connection.server_info.map:lower() then
    network.disconnect()
  end
  M.id_map = {}
  M.ownership = {}
  M.loading_map = false
  first_vehicle = true
  for k, vehicle in pairs(vehicle_buffer) do
    spawn_vehicle(vehicle)
  end
  vehicle_buffer = {}
end

M.onUpdate = onUpdate
M.update_vehicle = update_vehicle
M.send_vehicle_config = send_vehicle_config
M.send_vehicle_config_inner = send_vehicle_config_inner
M.spawn_vehicle = spawn_vehicle
M.update_vehicle_input = update_vehicle_input
M.update_vehicle_gearbox = update_vehicle_gearbox
M.rotate_nodes = rotate_nodes
M.remove_vehicle = remove_vehicle
M.reset_vehicle = reset_vehicle
M.update_vehicle_meta = update_vehicle_meta
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleResetted = onVehicleResetted
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onMissionLoaded = onMissionLoaded
M.onFreeroamLoaded = onMissionLoaded
M.electrics_diff_update = electrics_diff_update
M.attach_coupler = attach_coupler
M.detach_coupler = detach_coupler
M.attach_coupler_inner = attach_coupler_inner
M.detach_coupler_inner = detach_coupler_inner

return M
