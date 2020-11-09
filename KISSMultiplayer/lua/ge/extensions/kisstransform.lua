local M = {}

local generation = 0
local timer = 0
local velocity_buffer = {}
local angular_velocity_buffer = {}

local lerp_buffer = {}

local acceleration_buffer = {}
local angular_acceleration_buffer = {}

M.received_transforms = {}
M.local_transforms = {}

M.threshold = 3
M.rot_threshold = 2.5
M.velocity_error_limit = 10

local function get_current_time()
  local date = os.date("*t", os.time())
  date.sec = 0
  date.min = 0
  return (network.socket.gettime() - os.time(date)) + network.connection.time_offset
end

local function isnan(x)
  return x ~= x
end

local function isinf(x)
  return not (x > -math.huge and x < math.huge)
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
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
  if not M.local_transforms[id] then return end

  if not lerp_buffer[id] then
    lerp_buffer[id] = {
      velocity = vec3(transform.velocity),
      angular_velocity = vec3(transform.angular_velocity),
      acceleration = transform.acceleration,
      angular_acceleration = transform.angular_acceleration,
    }
  end

  transform.time_past = clamp(transform.time_past + dt, 0, 0.3)

  local local_ang_vel = vec3(
    M.local_transforms[id].vel_yaw,
    M.local_transforms[id].vel_pitch,
    M.local_transforms[id].vel_roll
  )

  local received_velocity = lerp(lerp_buffer[id].velocity, vec3(transform.velocity), dt * 4)
  local received_angular_velocity = lerp(lerp_buffer[id].angular_velocity, vec3(transform.angular_velocity), dt * 4)
  local received_acceleration = lerp(lerp_buffer[id].acceleration, transform.acceleration, dt)
  local received_angular_acceleration = lerp(lerp_buffer[id].angular_acceleration, transform.angular_acceleration, dt)
  lerp_buffer[id].velocity = received_velocity
  lerp_buffer[id].angular_velocity = received_angular_velocity
  lerp_buffer[id].acceleration = received_acceleration
  lerp_buffer[id].angular_acceleration = received_angular_acceleration

  local predicted_velocity = received_velocity + received_acceleration * transform.time_past
  local predicted_position = vec3(transform.position) + predicted_velocity * transform.time_past

  local predicted_angular_velocity = received_angular_velocity + received_angular_acceleration * transform.time_past
  local rotation_delta = predicted_angular_velocity * transform.time_past
  local predicted_rotation = quat(transform.rotation) * quatFromEuler(rotation_delta.x, rotation_delta.y, rotation_delta.z)

  local position_error = predicted_position - vec3(vehicle:getPosition())
  local rotation_error = predicted_rotation / quat(M.local_transforms[id].rotation)
  local rotation_error_euler = rotation_error:toEulerYXZ()

  if (rotation_error_euler:length() > M.rot_threshold) or (position_error:length() > 10) then
    vehicle:setPosRot(
      predicted_position.x,
      predicted_position.y,
      predicted_position.z,
      predicted_rotation.x,
      predicted_rotation.y,
      predicted_rotation.z,
      predicted_rotation.w
    )
    lerp_buffer[id] = {
      velocity = vec3(transform.velocity),
      angular_velocity = vec3(transform.angular_velocity),
      acceleration = transform.acceleration,
      angular_acceleration = transform.angular_acceleration,
    }
    return
  end

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

  -- Velocity is computed and applied past this point
  -- Return now if it's requested not to be applied
  if not apply_velocity then return end

  local acceleration = vec3(vehicle:getVelocity()) - (velocity_buffer[id] or vec3(vehicle:getVelocity()))
  velocity_buffer[id] = vec3(vehicle:getVelocity())
  local angular_acceleration = local_ang_vel - (angular_velocity_buffer[id] or local_ang_vel)
  angular_velocity_buffer[id] = local_ang_vel

  local velocity_error = vec3(transform.velocity) - vec3(vehicle:getVelocity())
  local error_length = velocity_error:length()
  if error_length > M.velocity_error_limit then
    velocity_error:normalize()
    velocity_error = velocity_error * M.velocity_error_limit
  end

  local angular_velocity_error = vec3(transform.angular_velocity) - local_ang_vel

  local required_acceleration = (velocity_error + position_error * 5) * math.min(dt * 5, 1)
  local required_angular_acceleration = (angular_velocity_error + rotation_error_euler * 5) * math.min(dt * 7, 1)

  local dot_acc = required_acceleration:dot((acceleration_buffer[id] or acceleration) - acceleration) / (required_acceleration:squaredLength() + 9 * dt)
  local dot_ang_acc = required_angular_acceleration:dot((angular_acceleration_buffer[id] or angular_acceleration) - angular_acceleration) / (required_angular_acceleration:squaredLength() + 9 * dt)

  required_acceleration = required_acceleration * (1 - clamp(dot_acc, 0, 1))
  required_angular_acceleration = required_angular_acceleration * (1 - clamp(dot_ang_acc, 0, 1))
 
  if required_acceleration:length() > 15 or isnan(required_acceleration.x) or isinf(required_acceleration.x) then return end
  if required_angular_acceleration:length() > 5 or isnan(required_angular_acceleration.x) or isinf(required_angular_acceleration.x) then return end

  if (required_acceleration:length() > 0.1) or (required_angular_acceleration:length() > 0.05) then
    vehicle:queueLuaCommand("kiss_vehicle.apply_full_velocity("
                              ..required_acceleration.x..","
                              ..required_acceleration.y..","
                              ..required_acceleration.z..","
                              ..required_angular_acceleration.y..","
                              ..required_angular_acceleration.z..","
                              ..required_angular_acceleration.x..")")
  end
 
  acceleration_buffer[id] = required_acceleration
  angular_acceleration_buffer[id] = required_angular_acceleration
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
    apply_transform(dt, id, transform, apply_velocity)
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
  local vehicle = be:getObjectByID(id)

  if vehicle then
    transform.time_past = clamp(get_current_time() - transform.sent_at, 0, 0.1) * 0.7 + 0.001

    if M.received_transforms[id] then
      local old_transform =  M.received_transforms[id]
      local old_velocity = vec3(old_transform.velocity)
      transform.acceleration = (vec3(transform.velocity) - old_velocity) / (transform.sent_at - old_transform.sent_at)
      local old_angular_velocity = vec3(M.received_transforms[id].angular_velocity)
      transform.angular_acceleration = (vec3(transform.angular_velocity) - old_angular_velocity) / transform.time_past
    else
      transform.acceleration = vec3(0, 0, 0)
      transform.angular_acceleration = vec3(0, 0, 0)
    end

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
