local M = {}

local generation = 0
local timer = 0
local buffered_position_errors = {}
local buffered_rotation_errors = {}
local buffered_ang_vel_errors = {}

M.received_transforms = {}
M.local_transforms = {}

M.threshold = 4
M.rot_threshold = 1.5
M.smoothing_coef = 4
M.angular_velocity_error_limit = 0.1
M.velocity_error_limit = 10
M.smoothing_coef_rot = 2.5

local function lerp(a,b,t)
  local t = math.min(t, 1)
  return a * (1-t) + b * t
end

local function get_current_time()
  local date = os.date("*t", os.time())
  date.sec = 0
  date.min = 0
  return network.socket.gettime() - os.time(date)
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

local function apply_transform(dt, id, transform, apply_velocity)
  transform.time_past = (transform.time_past or 0) + dt

  local predicted_position = vec3(transform.position) + vec3(transform.velocity) * transform.time_past
  local rotation_delta = vec3(transform.angular_velocity) * transform.time_past
  local predicted_rotation = quat(transform.rotation) * quatFromEuler(rotation_delta.x, rotation_delta.y, rotation_delta.z)

  local vehicle = be:getObjectByID(id)
  if vehicle and M.local_transforms[id] then
    local position_error = predicted_position - vec3(vehicle:getPosition())
    local rotation_error = predicted_rotation / quat(M.local_transforms[id].rotation)
    local rotation_error_euler = rotation_error:toEulerYXZ()
    if position_error:length() > M.threshold then
      vehicle:setPosition(
        Point3F(
          predicted_position.x,
          predicted_position.y,
          predicted_position.z
        )
      )
      return
    end
    
    if (rotation_error_euler:length() > M.rot_threshold) or (position_error:length() > 5) then
      vehicle:setPosRot(
        predicted_position.x,
        predicted_position.y,
        predicted_position.z,
        predicted_rotation.x,
        predicted_rotation.y,
        predicted_rotation.z,
        predicted_rotation.w
      )
      return
    end

    -- Velocity is computed and applied past this point
    -- Return now if it's requested not to be applied
    if not apply_velocity then return end

    --rotation_error = (buffered_rotation_errors[id] or rotation_error):slerp(rotation_error, dt * M.smoothing_coef_rot)
    --buffered_rotation_errors[id] = rotation_error

    if position_error:length() > 5 then
      position_error:normalize()
      position_error = position_error * 5
    end

    local velocity_error = vec3(transform.velocity) - vec3(vehicle:getVelocity())
    local error_length = velocity_error:length()

    if error_length > M.velocity_error_limit then
      velocity_error:normalize()
      velocity_error = velocity_error * M.velocity_error_limit
    end

    local local_ang_vel = vec3(
      M.local_transforms[id].vel_yaw,
      M.local_transforms[id].vel_pitch,
      M.local_transforms[id].vel_roll
    )
    local angular_velocity_error = vec3(transform.angular_velocity) - local_ang_vel

    local required_acceleration = (velocity_error + position_error * 5) * math.min(dt * 5, 1)
    local required_angular_acceleration = (angular_velocity_error + rotation_error_euler * 5) * math.min(dt * 7, 1)
    required_acceleration = required_acceleration * (1 - clamp((1 / (required_acceleration:squaredLength() + 64 * dt)), 0, 1))
    required_angular_acceleration = required_angular_acceleration * (1 - clamp((1 / (required_angular_acceleration:squaredLength() + 128 * dt)), 0, 1))

    if required_acceleration:length() > 500 then return end
    if required_angular_acceleration:length() > 500 then return end
    vehicle:queueLuaCommand("kiss_vehicle.apply_full_velocity("
                              ..required_acceleration.x..","
                              ..required_acceleration.y..","
                              ..required_acceleration.z..","
                              ..required_angular_acceleration.y..","
                              ..required_angular_acceleration.z..","
                              ..required_angular_acceleration.x..")")
  end
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

  if timer < (1/network.connection.tickrate) then
    timer = timer + dt
  else
    timer = 0
    for i, v in pairs(vehiclemanager.ownership) do
      local vehicle = be:getObjectByID(i)
      if vehicle then
        send_transform_updates(vehicle)
        vehicle:queueLuaCommand("kiss_electrics.send()")
        vehicle:queueLuaCommand("kiss_gearbox.send()")
      end
    end
  end

  -- Don't apply velocity while paused. If we do, velocity gets stored up and released when the game resumes.
  local apply_velocity = not bullettime.getPause()
  for id, transform in pairs(M.received_transforms) do
    apply_transform(dt, id, transform, apply_velocity)
  end
end

local function update_vehicle_transform(data)
  data = data..string.char(1)
  local p = ffi.new("char[?]", #data, data)
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
  if transform.generation < (vehiclemanager.packet_gen_buffer[id] or -1) then return end
  vehiclemanager.packet_gen_buffer[id] = transform.generation
  local vehicle = be:getObjectByID(id)
  if vehicle then
    transform.time_past = 0 --get_current_time() - transform.sent_at
    M.received_transforms[id] = transform
  end
end

local function push_transform(id, t)
  M.local_transforms[id] = jsonDecode(t)
end

M.send_vehicle_transform = send_vehicle_transform
M.update_vehicle_transform = update_vehicle_transform
M.push_transform = push_transform
M.onUpdate = update

return M
