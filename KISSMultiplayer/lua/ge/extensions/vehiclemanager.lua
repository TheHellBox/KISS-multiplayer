local M = {}

local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

local timer = 0
local vehicle_buffer = {}
local colors_buffer = {}

M.loading_map = false
M.id_map = {}
M.ownership = {}
M.vehicle_updates_buffer = {}
M.packet_gen_buffer = {}

local function color_eq(a, b)
  return (a[1] == b[1]) and (a[2] == b[2]) and {a[3] == b[3]} and {a[4] == b[4]}
end

local function colors_eq(a, b)
  return color_eq(a[1], b[1]) and color_eq(a[2], b[2]) and color_eq(a[3], b[3])
end

local function onUpdate(dt)
  if not network.connection.connected then return end

    -- Track color changes
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      local color = vehicle.color
      local palete_0 = vehicle.colorPalette0
      local palete_1 = vehicle.colorPalette1
      local colors = {
        {color.x, color.y, color.z, color.w},
        {palete_0.x, palete_0.y, palete_0.z, palete_0.w},
        {palete_1.x, palete_1.y, palete_1.z, palete_1.w}
      }
      if colors_buffer[vehicle:getID()] then
        if not colors_eq(colors, colors_buffer[vehicle:getID()]) then
          local data = {
            vehicle:getID(),
            colors
          }
          network.send_messagepack(14, true, jsonEncode(data))
          colors_buffer[vehicle:getID()] = colors
        end
      else
        colors_buffer[vehicle:getID()] = colors
      end
    end
  end

  for id, updates in pairs(M.vehicle_updates_buffer) do
    local vehicle = be:getObjectByID(id)
    if vehicle then
      if updates.electronics then
        vehicle:queueLuaCommand("kiss_electrics.apply(\'"..jsonEncode(updates.electrics).."\')")
      end
      if updates.gearbox then
        vehicle:queueLuaCommand("kiss_gearbox.apply(\'"..jsonEncode(updates.gearbox).."\')")
      end
    end
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
  -- Buffer the vehicles if map is not loaded yet
  if M.loading_map then
    table.insert(vehicle_buffer, data)
    return
  end

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

local function update_vehicle_electrics(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
  if not M.vehicle_updates_buffer[id] then M.vehicle_updates_buffer[id] = {} end
  M.vehicle_updates_buffer[id].electrics = data
  vehicle:queueLuaCommand("kiss_electrics.apply(\'"..jsonEncode(data).."\')")
end

local function update_vehicle_gearbox(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
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

local function remove_vehicle(id)
  local id = M.id_map[id] or -1
  local vehicle = be:getObjectByID(id)
  if vehicle then
    commands.setFreeCamera()
    vehicle:delete()
    if commands.isFreeCamera(player) then commands.setGameCamera() end
    M.id_map[id] = nil
    M.vehicle_updates_buffer[id] = nil
    kisstransform.received_transforms[id] = nil
  end
end

local function reset_vehicle(id)
  local id = M.id_map[id] or -1
  local vehicle = be:getObjectByID(id)
  if vehicle then
    vehicle:reset()
  end
end

--[[local function send_vehicle_data(parts_config, id)
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
  network.send_data(13, true, result)
  end]]--

local function update_vehicle_data(data)
  local vehicle = be:getObjectByID(id_map[data.server_id])
  if vehicle then
    vehicle:queueLuaCommand("kissvehicle.update_data(\'"..jsonEncode(data).."\')")
  end
end

local function update_vehicle_colors(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if vehicle then
    local colors = {
      data[2][1],
      data[2][2],
      data[2][3]
    }
    local vd = extensions.core_vehicle_manager.getVehicleData(objID)
    if not vd or not vd.config or not vd.config.colors then return end
    vd.config.colors = colors
    extensions.core_vehicle_manager.liveUpdateVehicleColors(id, vehicle)
  end
end

local function onVehicleSpawned(id)
  if not network.connection.connected then return end
  local vehicle = be:getObjectByID(id)
  vehicle:queueLuaCommand("extensions.addModulePath('lua/vehicle/extensions/kiss_mp')")
  vehicle:queueLuaCommand("extensions.loadModulesInDirectory('lua/vehicle/extensions/kiss_mp')")
  send_vehicle_config(id)
end

local function onVehicleDestroyed(id)
  if not network.connection.connected then return end
  local packed = ffi.string(ffi.new("uint32_t[?]", 1, {id}), 4)
  network.send_data(5, true, packed)
end

local function onVehicleResetted(id)
  if not network.connection.connected then return end
  local packed = ffi.string(ffi.new("uint32_t[?]", 1, {id}), 4)
  network.send_data(6, true, packed)
end

local function onFreeroamLoaded(mission)
  if not network.connection.connected then return end
  if mission ~= network.connection.server_info.map then
    M.loading_map = true
    freeroam_freeroam.startFreeroam(network.connection.server_info.map)
  end
 
  M.loading_map = false
  for _, data in pairs(vehicle_buffer) do
    spawn_vehicle(data)
  end
  vehicle_buffer = {}
end

M.onUpdate = onUpdate
M.send_vehicle_config = send_vehicle_config
M.send_vehicle_config_inner = send_vehicle_config_inner
M.spawn_vehicle = spawn_vehicle
M.update_vehicle_electrics = update_vehicle_electrics
M.update_vehicle_gearbox = update_vehicle_gearbox
M.rotate_nodes = rotate_nodes
M.remove_vehicle = remove_vehicle
M.reset_vehicle = reset_vehicle
M.update_vehicle_colors = update_vehicle_colors
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleResetted = onVehicleResetted
M.onVehicleSpawned = onVehicleSpawned
M.onFreeroamLoaded = onFreeroamLoaded

return M
