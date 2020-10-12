local M = {}

local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

local timer = 0
local rotations = {}
local generation = 0
M.id_map = {}
M.ownership = {}
M.threshold = 0
M.rot_threshold = 0.1
M.vehicle_updates_buffer = {}
M.packet_gen_buffer = {}
M.max_rotation_lenght = 0.05

local function lerp(a,b,t) return a * (1-t) + b * t end

local function send_transform_updates(obj)
  --if not M.ownership[obj:getID()] then return end
  if not rotations[obj:getID()] then return end
  local position = obj:getPosition()
  local velocity = obj:getVelocity()
  local result = {}
  local id = obj:getID()
 
  generation = generation + 1
  result[1] = obj:getID()
  result[2] = position.x
  result[3] = position.y
  result[4] = position.z
  result[5] = rotations[id][1] or 0
  result[6] = rotations[id][2] or 0
  result[7] = rotations[id][3] or 0
  result[8] = rotations[id][4] or 0
  result[9] = velocity.x
  result[10] = velocity.y
  result[11] = velocity.z
  result[12] = generation
  local packed = ffi.string(ffi.new("float[?]", #result, result), 4 * #result)
  network.send_data(0, false, packed)
end

local function onUpdate(dt)
  -- You can't just get rotations in GameEngine lua by calling veh:getRotation
  -- It'll return a wrong value.
  -- So instead we have to call vehicle lua, just to get this data from there.
  -- Ugh.
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand("kiss_vehicle.update_rotation()")
    end
  end
    -- You might think that updating vehicle state 60 times/sec is overkill
    -- But keep in mind that we also sync vehicle controls, and more precise they are,
    -- the less desync there is
  if timer < (1/60) then
    timer = timer + dt
  else
    timer = 0
    for i, v in pairs(M.ownership) do
      local vehicle = be:getObjectByID(i)
      if vehicle then
        send_transform_updates(vehicle)
        vehicle:queueLuaCommand("kiss_electrics.send()")
        vehicle:queueLuaCommand("kiss_gearbox.send()")
        --vehicle:queueLuaCommand("kiss_nodes.send()")
      end
    end
  end
    -- It's better to apply those values every frame.
    -- I'm not sure if it's acttualy better
    -- But I think so
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

local function update_vehicle_transform(transform)
  local id = M.id_map[transform.owner or -1] or -1
  if M.ownership[id] then return end
  if transform.generation < (M.packet_gen_buffer[id] or -1) then return end
  M.packet_gen_buffer[id] = transform.generation
  local vehicle = be:getObjectByID(id)
  local position = vec3(vehicle:getPosition())
  local rotation = quat(rotations[id] or {0, 0, 0, 1})
  local target_rotation = quat(transform.rotation)
  local current_velocity = vehicle:getVelocity()
  -- If desync is only about vehicle position, use more gentle setPosition.
  if position:squaredDistance(vec3(transform.position)) > M.threshold then
    vehicle:setPosition(
      Point3F(
        transform.position[1],
        transform.position[2],
        transform.position[3]
      )
    )
  end
    -- setPosRot resets vehicle state and velocity, so it's generaly should be called as little as possbile to avoid electrics desync.
    -- However, we use it's property of killing velocity to apply a new velocity to a car(kiss_vehicle.kill_velocity makes car extremly unstable)
    -- Also, it's a lot more stable than kiss_vehicle.set_rotation.
  if (target_rotation - rotation):norm() > M.rot_threshold then
    local r = target_rotation
    --vehicle:queueLuaCommand("kiss_vehicle.set_rotation("..r.x..", "..r.y..", "..r.z..", "..r.w..")")
    vehicle:setPosRot(
      transform.position[1],
      transform.position[2],
      transform.position[3],
      r.x,
      r.y,
      r.z,
      r.w
    )
    local x = transform.velocity[1]
    local y = transform.velocity[2]
    local z = transform.velocity[3]
    vehicle:queueLuaCommand("kiss_vehicle.apply_velocity("..x..", "..y..", "..z..", "..(2000)..")")
  end
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

local function push_rotation(id, x, y, z, w)
  rotations[id] = {x, y, z, w}
end

local function set_smoothness(x)
  lerp_smoothness = x
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
M.send_vehicle_transform = send_vehicle_transform
M.send_vehicle_config = send_vehicle_config
M.send_vehicle_config_inner = send_vehicle_config_inner
M.update_vehicle_transform = update_vehicle_transform
M.spawn_vehicle = spawn_vehicle
M.push_rotation = push_rotation
M.set_smoothness = set_smoothness
M.update_vehicle_electrics = update_vehicle_electrics
M.update_vehicle_gearbox = update_vehicle_gearbox
M.rotate_nodes = rotate_nodes

return M
