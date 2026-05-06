local M = {}

local show_drivers = false

M.lerp_factor = 5
M.players = {}
M.player_bodies = {}
M.player_heads_in_cars = {}
M.player_heads_attachments = {}
M.player_transforms = {}

local blacklist = {
  woodplanks = true,
  woodcrate = true,
  weightpad = true,
  wall = true,
  tv = true,
  tsfb = true,
  tube = true,
  trafficbarrel = true,
  tirewall = true,
  tirestacks = true,
  testroller = true,
  tanker = true,
  suspensionbridge = true,
  streetlight = true,
  shipping_container = true,
  sawhorse = true,
  rollover = true,
  rocks = true,
  roadsigns = true,
  piano = true,
  metal_ramp = true,
  metal_box = true,
  mattress = true,
  large_tilt = true,
  large_spinner = true,
  large_roller = true,
  large_hamster_wheel = true,
  large_crusher = true,
  large_cannon = true,
  large_bridge = true,
  large_angletester = true,
  kickplate = true,
  inflated_mat = true,
  haybale = true,
  gate = true,
  fridge = true,
  flipramp = true,
  flatbed = true,
  flail = true,
  couch = true,
  cones = true,
  christmas_tree = true,
  chair = true,
  cardboard_box = true,
  cannon = true,
  blockwall = true,
  barrier = true,
  barrels = true,
  ball = true,
  unicycle = true
}

local function get_player_color(id)
  math.randomseed(id)
  local r, g, b, a = 0.2 + math.random() * 0.8, 0.2 + math.random() * 0.8, 0.2 + math.random() * 0.8, 1
  math.randomseed(os.time())
  return r, g, b, a
end

local function spawn_player(data)
  -- Character models are hidden; only track transform data
  M.player_transforms[data.server_id] = {
    position = vec3(data.position),
    target_position = vec3(data.position),
    rotation = data.rotation,
    velocity = vec3(),
    time_past = 0
  }
end

local function delete_player_body(id)
  local obj = M.player_bodies[id]
  if obj and obj.delete then
    obj:delete()
    M.player_bodies[id] = nil
  end
end

local original_position = vec3()
local temp_vec = vec3()
local final_pos = vec3()
local function update_unicycle_replacements(dt)
  for id, data in pairs(M.player_transforms) do
    local player = M.player_bodies[id]
    if player and data then
      data.time_past = data.time_past + dt
      original_position:set(data.position)

      temp_vec:set(data.velocity)
      temp_vec:setScaled(data.time_past)
      temp_vec:setAdd(data.target_position)

      data.position:setLerp(original_position, temp_vec, clamp(dt * M.lerp_factor, 0, 1))

      temp_vec:setSub2(data.position, original_position) -- local_velocity

      -- local_velocity * dt + data.position
      final_pos:set(temp_vec)
      final_pos:setScaled(dt)
      final_pos:setAdd(original_position)

      local x, y, z = final_pos:xyz()
      player:setPosRot(
        x, y, z,
        data.rotation[1], data.rotation[2], data.rotation[3], data.rotation[4]
      )
    end
  end
end

local function spawn_player_head(id, veh_id)
  local player = createObject('TSStatic')
  player:setField("shapeName", 0, "/art/kissmp/playermodels/base_nb_head.dae")
  player:setField("dynamic", 0, "true")
  player.scale = vec3(1, 1, 1)
  local r, g, b, a = get_player_color(id)
  player:setField('instanceColor', 0, string.format("%g %g %g %g", r, g, b, a))
  player:registerObject("player_head"..id)

  M.player_heads_in_cars[id] = player
  M.player_heads_attachments[id] = veh_id
end

local function delete_player_head(id)
  local obj = M.player_heads_in_cars[id]
  if obj and obj.delete then
    obj:delete()
    M.player_heads_in_cars[id] = nil
    M.player_heads_attachments[id] = nil
  end
end

local camera_pos = vec3()
local distance_threshold = 2.5 * 2.5
local driver_cam_pos = vec3()
local vehicle_vel = vec3()
local function update_player_head(dt, player_id, vehicle)
  local cam_node, _ = core_camera.getDriverData(vehicle)
  local veh_id = vehicle:getID()
  local transform = kissmp_transform.local_transforms[veh_id]

  if cam_node and transform then
    driver_cam_pos:set(vehicle:getNodeAbsPositionXYZ(cam_node))
    local r = transform.rotation

    local hide = not show_drivers or kissmp_transform.inactive[veh_id]
    hide = hide or vehicle == getPlayerVehicle(0) and camera_pos:squaredDistance(driver_cam_pos) < distance_threshold
    if not hide and not M.player_heads_in_cars[player_id] then
      spawn_player_head(player_id, veh_id)
    end
    if hide and M.player_heads_in_cars[player_id] then
      delete_player_head(player_id)
    end

    vehicle_vel:set(vehicle:getVelocityXYZ())
    vehicle_vel:setScaled(dt)
    driver_cam_pos:setAdd(vehicle_vel)
    local player = M.player_heads_in_cars[player_id]
    if player then
      local x, y, z = driver_cam_pos:xyz()
      player:setPosRot(
        x, y, z,
        r[1], r[2], r[3], r[4]
      )
    end
  end
end

local function update_players(_, dt_sim)
  if kissmp_vehiclemanager and kissmp_vehiclemanager.loading_map then return end

  update_unicycle_replacements(dt_sim)

  camera_pos:set(core_camera.getPositionXYZ())
  for player_id, player_data in pairs(M.players) do
    local vehicleId = kissmp_vehiclemanager.id_map[player_data.current_vehicle or -1] or -1
    local vehicle = getObjectByID(vehicleId)

    if vehicle and not blacklist[vehicle:getJBeamFilename()] then
      update_player_head(dt_sim, player_id, vehicle)
    elseif M.player_heads_in_cars[player_id] then
      delete_player_head(player_id)
    end
  end
end

local function player_disconnect(data)
  local id = data
  M.players[id] = nil

  delete_player_head(id)
  delete_player_body(id)

  M.player_transforms[id] = nil
end

local function player_info_update(player_info)
  M.players[player_info.id] = player_info
end

local function onKissMPDisconnected()
  -- clear scene
  for id in pairs(M.player_heads_in_cars) do
    delete_player_head(id)
    delete_player_body(id)
  end

  M.players = {}
  M.player_bodies = {}
  M.player_transforms = {}
  M.player_heads_in_cars = {}
  M.player_heads_attachments = {}
end

local function onKissMPSettingsChanged(config)
  show_drivers = false
end

M.spawn_player = spawn_player
M.get_player_color = get_player_color
M.delete_player_body = delete_player_body
M.delete_player_head = delete_player_head
M.player_disconnect = player_disconnect
M.player_info_update = player_info_update

M.onUpdate = update_players
M.onKissMPDisconnected = onKissMPDisconnected
M.onKissMPSettingsChanged = onKissMPSettingsChanged
M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
end

return M
