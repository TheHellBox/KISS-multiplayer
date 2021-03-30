local M = {}
M.lerp_factor = 5
M.players = {}
M.player_transforms = {}

local function spawn_player(data)
  local player = createObject('TSStatic')
  player:setField("shapeName", 0, "/art/shapes/kissmp_playermodels/base_nb.dae")
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
      data.position = lerp(data.position, data.target_position + data.velocity * data.time_past, dt * M.lerp_factor)
      player:setPosRot(
        data.position.x, data.position.y, data.position.z,
        data.rotation[1], data.rotation[2], data.rotation[3], data.rotation[4]
      )
    end
  end
end

M.spawn_player = spawn_player
M.onUpdate = update_players

return M
