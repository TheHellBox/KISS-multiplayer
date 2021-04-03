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
  flipramp = true,
  flatbed = true,
  flail = true,
  cones = true,
  christmas_tree = true,
  cannon = true,
  blockwall = true,
  barrier = true,
  barrels = true,
  ball = true,
  unicycle = true
}

local current_camera_mode = ""

local function spawn_player(data)
  local player = createObject('TSStatic')
  player:setField("shapeName", 0, "/art/shapes/kissmp_playermodels/base_nb.dae")
  player:setField("dynamic", 0, "true")
  player.scale = Point3F(1, 1, 1)
  player:registerObject("player"..data.owner)
  player:setPosRot(
    data.position[1], data.position[2], data.position[3],
    data.rotation[1], data.rotation[2], data.rotation[3], data.rotation[4]
  )
  math.randomseed(data.owner)
  player:setField('instanceColor', 0, string.format("%g %g %g %g", 0.1 + math.random() * 0.9, 0.1 + math.random() * 0.9, 0.1 + math.random() * 0.9, 1))
  math.randomseed(os.time())
  vehiclemanager.id_map[data.server_id] = player:getID()
  vehiclemanager.server_ids[player:getID()] = data.server_id
  M.players[data.server_id] = player
  M.player_transforms[data.server_id] = {
    position = vec3(data.position),
    target_position = vec3(data.position),
    rotation = data.rotation,
    velocity = vec3(),
    time_past = 0
  }
end

local function update_players(dt)
  for id, data in pairs(M.player_transforms) do
    local player = M.players[id]
    if player and data then
      data.time_past = data.time_past + dt
      data.position = lerp(data.position, data.target_position + data.velocity * data.time_past, clamp(dt * M.lerp_factor, 0, 1))
      local p = data.position + data.velocity * dt
      --player.position = m
      player:setPosRot(
        p.x, p.y, p.z,
        data.rotation[1], data.rotation[2], data.rotation[3], data.rotation[4]
      )
    end
  end
  for id, player_data in pairs(network.players) do
    local vehicle = be:getObjectByID(vehiclemanager.id_map[player_data.current_vehicle or -1] or -1)
    if vehicle and (not blacklist[vehicle:getJBeamFilename()]) then
      local cam_node, _ = core_camera.getDriverData(vehicle)
      if cam_node and kisstransform.local_transforms[vehicle:getID()] then
        local p = vec3(vehicle:getNodePosition(cam_node)) + vec3(vehicle:getPosition()) + vec3(vehicle:getVelocity()) * dt
        local r = kisstransform.local_transforms[vehicle:getID()].rotation
        local hide = be:getPlayerVehicle(0) and (be:getPlayerVehicle(0):getID() == vehicle:getID()) and (vec3(getCameraPosition()):distance(p) < 2) --and (current_camera_mode == "driver")
        hide = hide or (not kissui.show_drivers[0])
        if (not M.players_in_cars[id]) and (not hide) then
          local player = createObject('TSStatic')
          player:setField("shapeName", 0, "/art/shapes/kissmp_playermodels/base_nb_head.dae")
          player:setField("dynamic", 0, "true")
          player.scale = Point3F(1, 1, 1)
          math.randomseed(id)
          player:setField('instanceColor', 0, string.format("%g %g %g %g", 0.1 + math.random() * 0.9, 0.1 + math.random() * 0.9, 0.1 + math.random() * 0.9, 1))
          math.randomseed(os.time())
          player:registerObject("player_head"..id)
          M.players_in_cars[id] = player
          M.player_heads_attachments[id] = vehicle:getID()
        end
        if hide and M.players_in_cars[id] then
          M.players_in_cars[id]:delete()
          M.players_in_cars[id] = nil
          M.player_heads_attachments[id] = nil
        end
        local player = M.players_in_cars[id]
        player:setPosRot(
          p.x, p.y, p.z,
          r[1], r[2], r[3], r[4]
        )
      end
    else
      if M.players_in_cars[id] then
        M.players_in_cars[id]:delete()
        M.players_in_cars[id] = nil
        M.player_heads_attachments[id] = nil
      end
    end
  end
  for id, v in pairs(M.players_in_cars) do
    if not be:getObjectByID(M.player_heads_attachments[id] or -1) then
      v:delete()
      M.players_in_cars[id] = nil
      M.player_heads_attachments[id] = nil
    end
  end
end

local function onCameraModeChanged(v)
  current_camera_mode = v
end

M.spawn_player = spawn_player
M.onUpdate = update_players
M.onCameraModeChanged = onCameraModeChanged

return M
