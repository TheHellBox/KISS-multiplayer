local M = {}

local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

local timer = 0
M.id_map = {}
local velocity_map = {}
M.ownership = {}
local rotations = {}
local transforms_buffer = {}
local extrapolation_enabled = false
local lerp_smoothness = 2.0
local generation = 0

local function lerp(a,b,t) return a * (1-t) + b * t end

local function send_transform_updates(obj)
  if not M.ownership[obj:getID()] then return end
  if not rotations[obj:getID()] then return end
  local position = obj:getPosition()
  local rotation = obj:getRotation()
  local velocity = obj:getVelocity()

  local result = {}
  local id = obj:getID()

  generation = generation + 1
  result[1] = obj:getID()
  result[2] = position.x or 0
  result[3] = position.y or 0
  result[4] = position.z or 0
  result[5] = rotations[id][1] or 0
  result[6] = rotations[id][2] or 0
  result[7] = rotations[id][3] or 0
  result[8] = rotations[id][4] or 0
  result[9] = generation
  local packed = ffi.string(ffi.new("float[?]", #result, result), 4 * #result)
  network.send_data(0, false, packed)
end

local function onUpdate(dt)
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand("kiss_vehicle.update_rotation()")
    end
  end
  if timer < (1/30) then
    timer = timer + dt
  else
    timer = 0
    for i, v in pairs(M.ownership) do
      local vehicle = be:getObjectByID(i)
      if vehicle then
        send_transform_updates(vehicle)
        vehicle:queueLuaCommand("kiss_electrics.send()")
        vehicle:queueLuaCommand("kiss_gearbox.send()")
      end
    end
  end
  for id, transform in pairs(transforms_buffer) do
    local vehicle = be:getObjectByID(M.id_map[id] or -1)
    if vehicle then
      local position = vec3(vehicle:getPosition())
      if position:squaredDistance(vec3(transform.position)) > 0 then
        vehicle:setPosRot(
          transform.position[1],
          transform.position[2],
          transform.position[3],
          transform.rotation[1],
          transform.rotation[2],
          transform.rotation[3],
          transform.rotation[4]
        )
      else
        local rotation = rotations[vehicle:getID()]
        local quat_buffer = quat(
          transform.rotation[1],
          transform.rotation[2],
          transform.rotation[3],
          transform.rotation[4]
        )
        local quat_current = quat(
          rotation[1],
          rotation[2],
          rotation[3],
          rotation[4]
        )
        local rotation_slerp = quat(0, 0, 0, 0)
        if quat_current:distance(quat_buffer) > 0.5 then
          rotation_slerp = quat_buffer
        else
          rotation_slerp = quat_current:slerp(quat_buffer, dt * lerp_smoothness)
        end
        vehicle:setPosRot(
          lerp(position.x, transform.position[1], dt * lerp_smoothness),
          lerp(position.y, transform.position[2], dt * lerp_smoothness),
          lerp(position.z, transform.position[3], dt * lerp_smoothness),
          rotation_slerp.x,
          rotation_slerp.y,
          rotation_slerp.z,
          rotation_slerp.w
        )
      end
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

local function update_vehicle_transform(transform)
  local id = M.id_map[transform.owner or -1] or -1
  if M.ownership[id] then return end
  if transforms_buffer[transform.owner] then
    if transform.generation < transform_buffer[transform.owner].generation then return end
  end
  transforms_buffer[transform.owner] = transform
end

local function update_vehicle_electrics(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  vehicle:queueLuaCommand("kiss_electrics.apply(\'"..jsonEncode(data).."\')")
end

local function update_vehicle_gearbox(data)
  local data = messagepack.unpack(data)
  local id = M.id_map[data[1] or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  vehicle:queueLuaCommand("kiss_gearbox.apply(\'"..jsonEncode(data).."\')")
end

local function push_rotation(id, x, y, z, w)
  rotations[id] = {x, y, z, w}
end

local function set_smoothness(x)
  lerp_smoothness = x
end

M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.send_vehicle_transform = send_vehicle_transform
M.send_vehicle_config = send_vehicle_config
M.send_vehicle_config_inner = send_vehicle_config_inner
M.update_vehicle_transform = update_vehicle_transform
M.spawn_vehicle = spawn_vehicle
M.push_rotation = push_rotation
M.set_smoothness = set_smoothness
M.update_vehicle_electrics = update_vehicle_electrics
M.update_vehicle_gearbox = update_vehicle_gearbox

return M
