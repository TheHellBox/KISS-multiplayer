local M = {}

local generation = 0
local timer = 0

M.received_transforms = {}
M.local_transforms = {}
M.raw_positions = {}

M.threshold = 3
M.rot_threshold = 2.5
M.velocity_error_limit = 10

local function get_current_time()
  local date = os.date("*t", os.time() + network.connection.time_offset)
  date.sec = 0
  date.min = 0
  return (network.socket.gettime() + network.connection.time_offset  - os.time(date))
end

local function send_transform_updates(obj)
  --if not M.ownership[obj:getID()] then return end
  if not M.local_transforms[obj:getID()] then return end
  local position = obj:getPosition()
  local velocity = obj:getVelocity()
  local result = {}
  local id = obj:getID()

  generation = generation + 1

  result[1] = obj:getID()

  result[2] = position.x
  result[3] = position.y
  result[4] = position.z

  result[5] = M.local_transforms[id].rotation[1] or 0
  result[6] = M.local_transforms[id].rotation[2] or 0
  result[7] = M.local_transforms[id].rotation[3] or 0
  result[8] = M.local_transforms[id].rotation[4] or 1

  result[9] = velocity.x
  result[10] = velocity.y
  result[11] = velocity.z

  result[12] = M.local_transforms[id].vel_pitch
  result[13] = M.local_transforms[id].vel_roll
  result[14] = M.local_transforms[id].vel_yaw

  result[15] = generation
  result[16] = get_current_time()
 
  local packed = ffi.string(ffi.new("float[?]", #result, result), 4 * #result)
  network.send_data(0, false, packed)
end

local function update(dt)
  if not network.connection.connected then return end
    -- Get rotation/angular velocity from vehicle lua
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand("kiss_vehicle.update_transform_info()")
    end
  end

  -- Don't apply velocity while paused. If we do, velocity gets stored up and released when the game resumes.
  local apply_velocity = not bullettime.getPause()
  for id, transform in pairs(M.received_transforms) do
    --apply_transform(dt, id, transform, apply_velocity)
    local vehicle = be:getObjectByID(id)
    if vehicle and apply_velocity then
      vehicle:queueLuaCommand("kiss_transforms.update("..dt..")")
    end
  end
end

local function update_vehicle_transform(data)
  local p = ffi.new("char[?]", #data + 1, data)
  local ptr = ffi.cast("float*", p)
  local transform = {}
  transform.position = {ptr[0], ptr[1], ptr[2]}
  transform.rotation = {ptr[3], ptr[4], ptr[5], ptr[6]}
  transform.velocity = {ptr[7], ptr[8], ptr[9]}
  transform.angular_velocity = {ptr[10], ptr[11], ptr[12]}
  transform.owner = ptr[13]
  transform.generation = ptr[14]
  transform.sent_at = ptr[15]

  local id = vehiclemanager.id_map[transform.owner or -1] or -1
  if vehiclemanager.ownership[id] then return end
  if transform.generation <= (vehiclemanager.packet_gen_buffer[id] or -1) then return end
  vehiclemanager.packet_gen_buffer[id] = transform.generation
  M.raw_positions[transform.owner or -1] = transform.position
 
  local vehicle = be:getObjectByID(id)
  if vehicle then
    transform.time_past = clamp(get_current_time() - transform.sent_at, 0, 0.1) * 0.7 + 0.001
    vehicle:queueLuaCommand("kiss_transforms.set_target_transform(\'"..jsonEncode(transform).."\')")
    M.received_transforms[id] = transform
  end
end

local function push_transform(id, t)
  M.local_transforms[id] = jsonDecode(t)
end

M.send_transform_updates = send_transform_updates
M.send_vehicle_transform = send_vehicle_transform
M.update_vehicle_transform = update_vehicle_transform
M.push_transform = push_transform
M.onUpdate = update

return M
