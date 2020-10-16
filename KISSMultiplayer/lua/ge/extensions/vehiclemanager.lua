local M = {}

local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

local timer = 0
M.id_map = {}
M.ownership = {}
M.vehicle_updates_buffer = {}
M.packet_gen_buffer = {}

local function onUpdate(dt)
  for id, updates in pairs(M.vehicle_updates_buffer) do
    local vehicle = be:getObjectByID(id)
    if updates.electronics then
      vehicle:queueLuaCommand("kiss_electrics.apply(\'"..jsonEncode(updates.electrics).."\')")
    end
    if updates.gearbox then
      vehicle:queueLuaCommand("kiss_gearbox.apply(\'"..jsonEncode(updates.gearbox).."\')")
    end
  end
end

local function send_vehicle_config(vehicle_id)
  local vehicle = be:getObjectByID(vehicle_id)
  vehicle:queueLuaCommand("obj:queueGameEngineLua(\"vehiclemanager.send_vehicle_config_inner("..vehicle_id..", '\"..jsonEncode(v.config)..\"')\")")
end

local function send_vehicle_config_inner(id, parts_config)
  for k, v in pairs(M.id_map) do
    if v == id then return end
  end

  local vehicle = be:getObjectByID(id)
  local parts_config = parts_config
  local color = vehicle.color
  local palete_0 = vehicle.colorPalette0
  local palete_1 = vehicle.colorPalette1

  local vehicle_data = {}
  vehicle_data.parts_config = parts_config
  vehicle_data.in_game_id = id
  vehicle_data.color = {color.x, color.y, color.z, color.w}
  vehicle_data.palete_0 = {palete_0.x, palete_0.y, palete_0.z, palete_0.w}
  vehicle_data.palete_1 = {palete_1.x, palete_1.y, palete_1.z, palete_1.w}
  vehicle_data.name = vehicle:getJBeamFilename()
  local result = jsonEncode(vehicle_data)
  if result then
    network.send_data(1, true, result)
  else
    print("failed to encode vehicle")
  end
end

local function spawn_vehicle(data)
  print("Trying to spawn vehicle")
  if data.owner == network.get_client_id() then
    print("Vehicle belongs to local client, setting ownership")
    M.id_map[data.server_id] = data.in_game_id
    M.ownership[data.in_game_id] = data.server_id
    return
  end
  if M.id_map[data.server_id] then return end
  local current_vehicle = be:getPlayerVehicle(0)
  local parts_config = jsonDecode(data.parts_config)
  local c = data.color
  local cp0 = data.palete_0
  local cp1 = data.palete_1
  local name = data.name
  print("Vehicle spawned")
  local spawned = spawn.spawnVehicle(
    name,
    serialize(parts_config),
    vec3(0,0,0),
    quat(0,0,0,0),
    ColorF(c[1],c[2],c[3],c[4]),
    ColorF(cp0[1],cp0[2],cp0[3],cp0[4]),
    ColorF(cp1[1],cp1[2],cp1[3],cp1[4])
  )
  if data.server_id then
    M.id_map[data.server_id] = spawned:getID()
  else
    print("ERROR: Server ID is invalid")
  end
  if current_vehicle then be:enterVehicle(0, current_vehicle) end
end

local function onVehicleSpawned(gameVehicleID)
  local vehicle = be:getObjectByID(gameVehicleID)
  vehicle:queueLuaCommand("extensions.addModulePath('lua/vehicle/extensions/kiss_mp')")
  vehicle:queueLuaCommand("extensions.loadModulesInDirectory('lua/vehicle/extensions/kiss_mp')")
  send_vehicle_config(gameVehicleID)
end

local function update_vehicle_electrics(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if not M.vehicle_updates_buffer[id] then M.vehicle_updates_buffer[id] = {} end
  M.vehicle_updates_buffer[id].electrics = data
  vehicle:queueLuaCommand("kiss_electrics.apply(\'"..jsonEncode(data).."\')")
end

local function update_vehicle_gearbox(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if not M.vehicle_updates_buffer[id] then M.vehicle_updates_buffer[id] = {} end
  M.vehicle_updates_buffer[id].gearbox = data
  vehicle:queueLuaCommand("kiss_gearbox.apply(\'"..jsonEncode(data).."\')")
end

  -- This function is mainly used in context with kiss_vehicle.set_rotation
local function rotate_nodes(nodes, id, x, y, z, w)
  local nodes = jsonDecode(nodes)
  local vehicle = be:getObjectByID(id)
  local matrix = QuatF(x, y, z, w):getMatrix()
  local result = {}
  for id, position in pairs(nodes) do
    local point = matrix:transformP3F(
      Point3F(
        position[1],
        position[2],
        position[3]
      )
    )
    result[id] = {point.x, point.y, point.z}
  end
  vehicle:queueLuaCommand("kiss_nodes.apply(\'"..jsonEncode(result).."\')")
end

M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.send_vehicle_config = send_vehicle_config
M.send_vehicle_config_inner = send_vehicle_config_inner
M.spawn_vehicle = spawn_vehicle
M.update_vehicle_electrics = update_vehicle_electrics
M.update_vehicle_gearbox = update_vehicle_gearbox
M.rotate_nodes = rotate_nodes

return M
