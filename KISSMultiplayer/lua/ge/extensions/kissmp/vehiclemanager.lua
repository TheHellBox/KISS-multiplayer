local M = {}

local string_buffer = require("string.buffer")

local timer = 0
local generation = 0
local meta_timer = 0
local colors_buffer = {}
local plates_buffer = {}
local first_vehicle = true
local pending_unicycle_cleanup = {}

M.id_map = {}
M.server_ids = {}
M.ownership = {}
M.vehicle_updates_buffer = {}
M.packet_gen_buffer = {}
M.delay_spawns = false
M.vehicle_buffer = {}

local function get_current_time()
  local date = os.date("*t", os.time() + kissmp_network.connection.time_offset)
  date.sec = 0
  date.min = 0
  return (kissmp_network.socket.gettime() + kissmp_network.connection.time_offset  - os.time(date))
end

local function enable_spawning(enabled)
  local jsCommand = 'angular.element(document.body).injector().get("VehicleSelectConfig").configs.default.hide = {"spawnNew":' .. tostring(not enabled) .. '}'
  be:executeJS(jsCommand)
end

local function color_to_table(color, metal_data)
  return {color.x, color.y, color.z, color.w, metal_data.metallic, metal_data.roughness, metal_data.clearcoat, metal_data.clearcoatRoughness}
end

local function table_to_color(t)
  return {baseColor = {t[1], t[2], t[3], t[4]}, metallic = t[5], roughness = t[6], clearcoat = t[7], clearcoatRoughness = t[8]}
end

local function table_to_paint(t)
  return createVehiclePaint({x=t[1], y=t[2], z=t[3], w=t[4]}, {t[5], t[6], t[7], t[8]})
end

local function color_eq(a, b)
  local color_eq = (a[1] == b[1]) and (a[2] == b[2]) and (a[3] == b[3]) and (a[4] == b[4])
  local metal_eq = (a[5] == b[5]) and (a[6] == b[6]) and (a[7] == b[7]) and (a[8] == b[8])
  return color_eq and metal_eq
end

local function colors_eq(a, b)
  return color_eq(a[1], b[1]) and color_eq(a[2], b[2]) and color_eq(a[3], b[3])
end

local function send_vehicle_update(obj)
  if not kissmp_transform.local_transforms[obj:getID()] then return end
  local t = kissmp_transform.local_transforms[obj:getID()]
  if not t.input then return end
  if not t.gearbox then return end
  local rotation = t.rotation
  if obj:getJBeamFilename() == "unicycle" then
    local q = quat(getCameraQuat()):toEulerYXZ()
    local q = quatFromEuler(0.0, 0.0, q.x)
    rotation = {q.x, q.y, q.z, q.w}
  end
  local position = obj:getPosition()
  local velocity = obj:getVelocity()
  local result = {
    transform = {
      position = {position.x, position.y, position.z},
      rotation = rotation,
      velocity = {velocity.x, velocity.y, velocity.z},
      angular_velocity = {t.vel_pitch, t.vel_roll, t.vel_yaw}
    },
    electrics = t.input,
    gearbox = t.gearbox,
    vehicle_id = obj:getID(),
    generation = generation,
    sent_at = get_current_time()
  }
  generation = generation + 1
  kissmp_network.send_data(
    {
      VehicleUpdate = result
    },
    false
  )
end

local function send_vehicle_meta_updates()
  for id in pairs(M.ownership) do
    local vehicle = getObjectByID(id)
    if vehicle and not kissmp_transform.inactive[id] then
      local changed = false

      local metal_data = vehicle:getMetallicPaintData()
      local color = vehicle.color
      local palete_0 = vehicle.colorPalette0
      local palete_1 = vehicle.colorPalette1
      local plate = vehicle.licenseText
      local colors = {
        color_to_table(color, metal_data[1]),
        color_to_table(palete_0, metal_data[2]),
        color_to_table(palete_1, metal_data[3])
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
        kissmp_network.send_data(data, true)
      end
    end
  end
end

local function update_ownership_limits()
  local owned_vehicle_count = 0
  for _, _ in pairs(M.ownership) do
    owned_vehicle_count = owned_vehicle_count + 1
  end
  if owned_vehicle_count >= kissmp_network.connection.server_info.max_vehicles_per_client then
    enable_spawning(false)
  else
    enable_spawning(true)
  end
end

local function send_vehicle_config(vehicle_id)
  local vehicle = getObjectByID(vehicle_id)
  if vehicle then
    vehicle:queueLuaCommand("kissmp_vehicle.send_vehicle_config()")
  end
end

local function send_vehicle_config_inner(id, parts_config_json, buffer_data)
  local data = string_buffer.decode(buffer_data)
  for k, v in pairs(M.id_map) do
    if v == id and not M.ownership[id] then return end
  end

  local vehicle = getObjectByID(id)
  local metal_data = vehicle:getMetallicPaintData()
  local color = vehicle.color
  local palete_0 = vehicle.colorPalette0
  local palete_1 = vehicle.colorPalette1
  local plate = vehicle.licenseText
  local position = vec3(data.position)
  local rotation = quat(data.rotation)
  local vehicle_data = {}
  vehicle_data.parts_config = parts_config_json
  vehicle_data.in_game_id = id
  vehicle_data.color = color_to_table(color, metal_data[1])
  vehicle_data.palete_0 = color_to_table(palete_0, metal_data[2])
  vehicle_data.palete_1 = color_to_table(palete_1, metal_data[3])
  vehicle_data.plate = plate
  vehicle_data.name = vehicle:getJBeamFilename()
  vehicle_data.position = {position.x, position.y, position.z}
  vehicle_data.rotation = {rotation.x, rotation.y, rotation.z, rotation.w}
  vehicle_data.server_id = 0
  vehicle_data.owner = 0
  kissmp_network.send_data(
    {
      VehicleData = vehicle_data
    },
    true
  )
end

local function electrics_diff_update(data)
  local id = M.id_map[data[1] or -1]
  if id and not M.ownership[id] then
    local vehicle = getObjectByID(id)
    if not vehicle then return end
    vehicle:queueLuaCommand(string.format(
      "kissmp_electrics.apply_diff(%q)",
      string_buffer.encode(data[2].diff)))
  end
end

local function controllers_diff_update(data)
  local id = M.id_map[data[1] or -1]
  if id and not M.ownership[id] then
    local vehicle = getObjectByID(id)
    if not vehicle then return end
    vehicle:queueLuaCommand(string.format(
      "kissmp_controllers.apply_diff(%q)",
      string_buffer.encode(data[2].diff)))
  end
end

local camera_pos = vec3()
local transform_pos = vec3()
local view_distance = nil

local function spawn_vehicle(server_data)
  local data, electrics, controllers = server_data[1], server_data[2], server_data[3]

  local model_info = core_vehicles.getModel(data.name)
  if tableSize(model_info) == 0 then
    log("W", "kissmp_vehiclemanager.spawn_vehicle", "Rejected modded vehicle spawn "..data.name)
    return
  end

  local away = true
  if view_distance then
    if kissmp_transform.raw_transforms[data.server_id] then
      local position = kissmp_transform.raw_transforms[data.server_id].position
      transform_pos:set(position[1], position[2], position[3])
      away = transform_pos:squaredDistance(camera_pos) > view_distance
    else
      local position = data.position
      transform_pos:set(position[1], position[2], position[3])
      away = transform_pos:squaredDistance(camera_pos) > view_distance
    end
  end

  if kissmp_levelmanager.is_loading or M.delay_spawns then
    log("D", "kissmp_vehiclemanager.spawn_vehicle", "Buffering vehicle")
    M.vehicle_buffer[data.server_id] = server_data
    return
  elseif away and view_distance then
    log("D", "kissmp_vehiclemanager.spawn_vehicle", "Buffering vehicle")
    M.vehicle_buffer[data.server_id] = server_data
    return
  end
  if data.owner == kissmp_network.get_client_id() then
    log("I", "kissmp_vehiclemanager.spawn_vehicle", "Vehicle belongs to local client, setting ownership")
    M.id_map[data.server_id] = data.in_game_id
    M.ownership[data.in_game_id] = data.server_id
    M.server_ids[data.in_game_id] = data.server_id
    update_ownership_limits()
    getObjectByID(data.in_game_id):queueLuaCommand("extensions.hook('kissUpdateOwnership', true)")
    return
  end
  if M.id_map[data.server_id] then return end
  local parts_config = jsonDecode(data.parts_config)
  local c = data.color
  local plate = data.plate
  local cp0 = data.palete_0
  local cp1 = data.palete_1
  local name = data.name
  if name == "unicycle" then
    kissmp_players.spawn_player(data)
    return
  end

  log("D", "kissmp_vehiclemanager.spawn_vehicle", "Attempt to spawn vehicle "..name)
  local options = {
    vehicleName = "mp_veh",
    pos = vec3(data.position),
    rot = quat(data.rotation),
    config = serialize(parts_config),
    paint  = table_to_paint(c),
    paint2 = table_to_paint(cp0),
    paint3 = table_to_paint(cp1),
    autoEnterVehicle = false
  }
  options = sanitizeVehicleSpawnOptions(name, options)

  local spawned = spawn.spawnVehicle(name, options.config, options.pos, options.rot, options)
  if not spawned then return end
  local p = data.position
  local r = data.rotation
  spawned:setPositionRotation(p[1], p[2], p[3], r[1], r[2], r[3], r[4])
  if plate ~= nil then
    extensions.core_vehicles.setPlateText(plate, spawned:getID())
  end
  M.id_map[data.server_id] = spawned:getID()
  M.server_ids[spawned:getID()] = data.server_id
  kissmp_transform.inactive[spawned:getID()] = false
  --if current_vehicle then be:enterVehicle(0, current_vehicle) end
  spawned:queueLuaCommand("extensions.hook('kissUpdateOwnership', false)")
  if electrics and controllers then
    spawned:queueLuaCommand(string.format(
      [[kissmp_electrics.apply_diff(%q);
        kissmp_controllers.apply_diff(%q)]],
      string_buffer.encode(electrics.diff),
      string_buffer.encode(controllers.diff)))
  end
end
-- Defers unicycle deletion until the next tick, as the game still refers to the to-be deleted ID in the current tick
local function queue_unicycle_cleanup(except_id)
  for vid, vehicle in vehiclesIterator() do
    if vehicle:getJBeamFilename() == "unicycle" and vid ~= except_id then
      pending_unicycle_cleanup[vid] = true
    end
  end
end

local function cleanup_pending_unicycles()
  for id in pairs(pending_unicycle_cleanup) do
    local vehicle = getObjectByID(id)
    if vehicle and vehicle:getJBeamFilename() == "unicycle" then
      vehicle:delete()
    end
    pending_unicycle_cleanup[id] = nil
  end
end

local function onUpdate(dt)
  camera_pos:set(core_camera.getPositionXYZ())

  cleanup_pending_unicycles()

  -- Track color and plate changes
  meta_timer = meta_timer + dt
  if meta_timer >= 1 then
    send_vehicle_meta_updates()
    meta_timer = meta_timer - 1
  end

  local tick_time = (1/kissmp_network.connection.tickrate)
  if timer <  tick_time then
    timer = timer + dt
  else
    timer = timer - tick_time
    for i, v in pairs(M.ownership) do
      local vehicle = getObjectByID(i)
      if vehicle and (not kissmp_transform.inactive[i]) then
        send_vehicle_update(vehicle)
        vehicle:queueLuaCommand("kissmp_electrics.send(); kissmp_controllers.send()")
      end
    end
  end

  for k, v in pairs(M.id_map) do
    if not M.ownership[v] then
      local vehicle = getObjectByID(v)
      if vehicle and (not kissmp_transform.inactive[v]) then
        vehicle:queueLuaCommand("kissmp_vehicle.update_eligible_nodes()")
      end
    end
  end
  if not (kissmp_levelmanager.is_loading or M.delay_spawns) then
    local to_remove = {}
    for k, vehicle_server_data in pairs(M.vehicle_buffer) do
      local t = kissmp_transform.raw_transforms[k]
      if t then
        transform_pos:set(t.position[1], t.position[2], t.position[3])
        if not (view_distance and transform_pos:squaredDistance(camera_pos) > view_distance) then
          spawn_vehicle(vehicle_server_data)
          table.insert(to_remove, k)
        end
      end
    end
    for _, v in pairs(to_remove) do
      M.vehicle_buffer[v] = nil
    end
  end
end

local function update_vehicle(data)
  kissmp_transform.raw_transforms[data.vehicle_id] = data.transform
  -- If vehicle is a unicycle(Walking mode character), sync it differently
  local character = kissmp_players.player_bodies[data.vehicle_id]
  if character then
    local character_transforms = kissmp_players.player_transforms[data.vehicle_id]
    if not character_transforms then
      character_transforms = {
        target_position = vec3(),
        rotation = {},
        velocity = vec3()
      }
      kissmp_players.player_transforms[data.vehicle_id] = character_transforms
    end

    local temp = data.transform.position
    character_transforms.target_position:set(temp[1], temp[2], temp[3])
    character_transforms.rotation = data.transform.rotation
    temp = data.transform.velocity
    character_transforms.velocity:set(temp[1], temp[2], temp[3])
    character_transforms.time_past = clamp(get_current_time() - data.sent_at, 0, 0.3) + 0.0001
    return
  end

  local id = M.id_map[data.vehicle_id]
  if not id then return end
  if M.ownership[id] then return end
  if data.generation <= (M.packet_gen_buffer[id] or -1) then return end
  M.packet_gen_buffer[id] = data.generation
  local vehicle = getObjectByID(id)
  if not vehicle then return end

  kissmp_transform.update_vehicle_transform(data)
  if not kissmp_transform.inactive[id] then
    vehicle:queueLuaCommand(string.format(
      [[kissmp_input.apply(%q)
        kissmp_gearbox.apply(%q)]],
      string_buffer.encode(data.electrics),
      string_buffer.encode(data.gearbox)))
  end
end

local function remove_vehicle(data)
  local id = data
  if kissmp_players.player_bodies[id] then
    kissmp_players.delete_player_body(id)
    kissmp_players.player_transforms[id] = nil
    return
  end
  local local_id = M.id_map[id] or -1
  local vehicle = getObjectByID(local_id)
  if vehicle then
    vehicle:setActive(1)
    vehicle:delete()
    M.id_map[id] = nil
    M.ownership[local_id] = nil
    M.vehicle_updates_buffer[local_id] = nil
    kissmp_transform.received_transforms[local_id] = nil
    update_ownership_limits()
  else
    M.vehicle_buffer[id] = nil
  end
end

local function reset_vehicle(data)
  local id = data.vehicle_id
  id = M.id_map[id] or -1

  local position = data.position
  local rotation = data.rotation

  local vehicle = getObjectByID(id)
  if not vehicle then return end
  if vehicle then
    vehicle:reset()
    vehicle:setPositionRotation(
      position[1],
      position[2],
      position[3],
      rotation[1],
      rotation[2],
      rotation[3],
      rotation[4]
    )
  end
end

local function update_vehicle_meta(data)
  local id = M.id_map[data.vehicle_id or -1] or -1
  if M.ownership[id] then return end
  local vehicle = getObjectByID(id)
  if not vehicle then return end
  local plate = data.plate

  local color = data.colors_table[1]
  local palete_0 = data.colors_table[2]
  local palete_1 = data.colors_table[3]
  local color_tables = {
    color,
    palete_0,
    palete_1
  }
  -- Apply plate
  if plate ~= nil then
    extensions.core_vehicles.setPlateText(plate, id)
  end

  -- Apply colors
  local vd = extensions.core_vehicle_manager.getVehicleData(id)
  if not vd or not vd.config or not vd.config.paints then return end

  for i=1,3 do
    local ct = color_tables[i]
    vd.config.paints[i] =  table_to_paint(ct)
    extensions.core_vehicle_manager.liveUpdateVehicleColors(id, vehicle, i, table_to_color(ct))
  end
  vehicle:setField('partConfig', '', serialize(vd.config))
end

local function attach_coupler_inner(buffer_data)
  local data = string_buffer.decode(buffer_data)
  data.obj_a = M.server_ids[data.obj_a]
  data.obj_b = M.server_ids[data.obj_b]
  kissmp_network.send_data(
    {
      CouplerAttached = data
    },
    true
  )
end

local function detach_coupler_inner(buffer_data)
  local data = string_buffer.decode(buffer_data)
  data.obj_a = M.server_ids[data.obj_a]
  data.obj_b = M.server_ids[data.obj_b]
  kissmp_network.send_data(
    {
      CouplerDetached = data
    },
    true
  )
end

local tempVec1 = vec3()
local tempVec2 = vec3()
local nodeAPos = vec3()
local nodeBPos = vec3()
local distanceThreshold = 15 * 15
local function attach_coupler(data)
  local obj_a = M.id_map[data.obj_a]
  local obj_b = M.id_map[data.obj_b]
  if obj_a and obj_b then
    if M.ownership[obj_a] then return end
    local vehicle = getObjectByID(obj_a)
    local vehicle_b = getObjectByID(obj_b)
    if not vehicle or not vehicle_b then return end

    tempVec1:set(vehicle:getPositionXYZ())
    tempVec2:set(vehicle_b:getPositionXYZ())
    if tempVec1:squaredDistance(tempVec2) > distanceThreshold then return end

    --[[
    local node_a_pos = vehicle:getNodeAbsPosition(data.node_a_id)
    local node_b_pos = vehicle_b:getNodeAbsPosition(data.node_b_id)
    local pos = vehicle_b:getPosition() + (node_a_pos - node_b_pos)
    ]]

    nodeAPos:set(vehicle:getNodeAbsPositionXYZ(data.node_a_id))
    nodeBPos:set(vehicle_b:getNodeAbsPositionXYZ(data.node_b_id))
    tempVec2:setAdd(nodeAPos)
    tempVec2:setSub(nodeBPos)

    vehicle_b:setPositionNoPhysicsReset(tempVec2)
    vehicle_b:queueLuaCommand("kissmp_couplers.attach_coupler("..data.node_b_id..")")
    onCouplerAttached(obj_a, obj_b, data.node_a_id, data.node_b_id)
  end
end

local function detach_coupler(data)
  local obj_a = M.id_map[data.obj_a]
  local obj_b = M.id_map[data.obj_b]
  if obj_a and obj_b then
    if M.ownership[obj_a] then return end
    local vehicle = getObjectByID(obj_a)
    local vehicle_b = getObjectByID(obj_b)
    if not vehicle or not vehicle_b then return end

    tempVec1:set(vehicle:getPositionXYZ())
    tempVec2:set(vehicle_b:getPositionXYZ())
    if tempVec1:squaredDistance(tempVec2) > distanceThreshold then return end

    vehicle:queueLuaCommand("kissmp_couplers.detach_coupler("..data.node_a_id..")")
    onCouplerDetached(obj_a, obj_b, data.node_a_id, data.node_b_id)
    onCouplerDetach(obj_a, data.node_a_id)
    onCouplerDetach(obj_b, data.node_b_id)
  end
end

local function set_position(data)
  local id = M.id_map[data[1] or -1] or -1
  local vehicle = getObjectByID(id)
  if vehicle then
    tempVec1:set(data[2][1], data[2][2], data[2][3])
    vehicle:setPositionNoPhysicsReset(tempVec1)
  end
end

local function set_position_rotation(data)
  local id = M.id_map[data[1] or -1] or -1
  local vehicle = getObjectByID(id)
  if vehicle then
    vehicle:setPosRot(data[2][1], data[2][2], data[2][3], data[3][1], data[3][2], data[3][3], data[3][4])
  end
end

local function reset_in_place(data)
  local id = M.id_map[data or -1] or -1
  local vehicle = getObjectByID(id)
  if vehicle then
    vehicle:reset()
  end
end

local function onVehicleSpawned(id)
  local vehicle = getObjectByID(id)
  tempVec1:set(vehicle:getPositionXYZ())
  if first_vehicle then
    tempVec2:set(tempVec1.x + math.random(-5, 5), tempVec1.y + math.random(-5, 5), tempVec1.z)
    vehicle:setPosition(tempVec2)
    vehicle:queueLuaCommand("recovery.saveHome()")
    first_vehicle = false
  end
  vehicle:queueLuaCommand("extensions.load('kissmp_main')")
  send_vehicle_config(id)
  -- Attempt to workaround a bug from latest beamng update. Also prevents unicycle cloning(Somewhat)
  if vehicle:getJBeamFilename() == "unicycle" then
    queue_unicycle_cleanup(vehicle:getID())
  end
end

local function onVehicleDestroyed(id)
  if M.ownership[id] then
    M.id_map[M.ownership[id]] = nil
    M.ownership[id] = nil
    kissmp_network.send_data(
      {
        RemoveVehicle = id,
      },
      true
    )
    update_ownership_limits()
  end
end

local function onVehicleResetted(id)
  if M.ownership[id] then
    local vehicle = getObjectByID(id)
    local data = { vehicle_id = id, position = {vehicle:getPositionXYZ()}, rotation = vehicle:getRefNodeRotation():toTable()}

    kissmp_network.send_data(
      {
        ResetVehicle = data,
      },
      true
    )
  end
end

local function onVehicleSwitched(_id, new_id)
  queue_unicycle_cleanup(new_id)
  if M.ownership[new_id] then
    kissmp_network.send_data(
      {
        VehicleChanged = new_id,
      },
      true
    )
  end
end

local function onKissMPSettingsChanged(config)
  view_distance = config["perf.enable_view_distance"] and config["perf.view_distance"] * config["perf.view_distance"] or nil
end

M.onUpdate = onUpdate
M.onKissMPSettingsChanged = onKissMPSettingsChanged
M.get_current_time = get_current_time
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
M.electrics_diff_update = electrics_diff_update
M.controllers_diff_update = controllers_diff_update
M.attach_coupler = attach_coupler
M.detach_coupler = detach_coupler
M.attach_coupler_inner = attach_coupler_inner
M.detach_coupler_inner = detach_coupler_inner

M.set_position = set_position
M.set_position_rotation = set_position_rotation
M.reset_in_place = reset_in_place

M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
end

return M
