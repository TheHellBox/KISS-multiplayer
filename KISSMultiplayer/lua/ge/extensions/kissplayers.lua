local M = {}
M.lerp_factor = 5
M.players = {}
M.players_in_cars = {}
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
  local player = createObject('TSStatic')
  player:setField("shapeName", 0, "/art/shapes/kissmp_playermodels/base_nb.dae")
  player:setField("dynamic", 0, "true")
  player.scale = vec3(1, 1, 1)
  player:registerObject("player"..data.owner)

  local r, g, b, a = get_player_color(data.owner)
  player:setField('instanceColor', 0, string.format("%g %g %g %g", r, g, b, a))
  player:setPosRot(
    data.position[1], data.position[2], data.position[3],
    data.rotation[1], data.rotation[2], data.rotation[3], data.rotation[4]
  )

  local player_mesh_id = player:getID()
  vehiclemanager.id_map[data.server_id] = player_mesh_id
  vehiclemanager.server_ids[player_mesh_id] = data.server_id

  M.players[data.server_id] = player
  M.player_transforms[data.server_id] = {
    position = vec3(data.position),
    target_position = vec3(data.position),
    rotation = data.rotation,
    velocity = vec3(),
    time_past = 0
  }
end

local original_position = vec3()
local temp_vec = vec3()
local final_pos = vec3()
local function update_unicycle_replacements(dt)
  for id, data in pairs(M.player_transforms) do
    local player = M.players[id]
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
  player:setField("shapeName", 0, "/art/shapes/kissmp_playermodels/base_nb_head.dae")
  player:setField("dynamic", 0, "true")
  player.scale = vec3(1, 1, 1)
  local r, g, b, a = get_player_color(id)
  player:setField('instanceColor', 0, string.format("%g %g %g %g", r, g, b, a))
  player:registerObject("player_head"..id)

  M.players_in_cars[id] = player
  M.player_heads_attachments[id] = veh_id
end

local function delete_player_head(id)
  M.players_in_cars[id]:delete()
  M.players_in_cars[id] = nil
  M.player_heads_attachments[id] = nil
end

local camera_pos = vec3()
local distance_threshold = 2.5 * 2.5
local driver_cam_pos = vec3()
local vehicle_vel = vec3()
local function update_player_head(dt, player_id, vehicle)
  local cam_node, _ = core_camera.getDriverData(vehicle)
  local veh_id = vehicle:getID()
  local transform = kisstransform.local_transforms[veh_id]

  if cam_node and transform then
    driver_cam_pos:set(vehicle:getNodeAbsPositionXYZ(cam_node))
    local r = transform.rotation

    local hide = not kissui.show_drivers[0] or kisstransform.inactive[veh_id]
    hide = hide or vehicle == getPlayerVehicle(0) and camera_pos:squaredDistance(driver_cam_pos) < distance_threshold
    if not hide and not M.players_in_cars[player_id] then
      spawn_player_head(player_id, veh_id)
    end
    if hide and M.players_in_cars[player_id] then
      delete_player_head(player_id)
    end

    vehicle_vel:set(vehicle:getVelocityXYZ())
    vehicle_vel:setScaled(dt)
    driver_cam_pos:setAdd(vehicle_vel)
    local player = M.players_in_cars[player_id]
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
  if vehiclemanager and vehiclemanager.loading_map then return end

  update_unicycle_replacements(dt_sim)

  camera_pos:set(core_camera.getPositionXYZ())
  for player_id, player_data in pairs(network.players) do
    local vehicleId = vehiclemanager.id_map[player_data.current_vehicle or -1] or -1
    local vehicle = getObjectByID(vehicleId)

    if vehicle and not blacklist[vehicle:getJBeamFilename()] then
      update_player_head(dt_sim, player_id, vehicle)
    elseif M.players_in_cars[player_id] then
      delete_player_head(player_id)
    end
  end
end

M.spawn_player = spawn_player
M.delete_player_head = delete_player_head

M.get_player_color = get_player_color
M.onUpdate = update_players

return M
