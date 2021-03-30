local M = {}

M.received_transform = {
  position = vec3(0, 0, 0),
  rotation = quat(0, 0, 0, 1),
  velocity = vec3(0, 0, 0),
  angular_velocity = vec3(0, 0, 0),
  acceleration = vec3(0, 0, 0),
  angular_acceleration = vec3(0, 0, 0),
  sent_at = 0,
  time_past = 0
}

M.target_transform = {
  position = vec3(0, 0, 0),
  rotation = quat(0, 0, 0, 1),
  velocity = vec3(0, 0, 0),
  angular_velocity = vec3(0, 0, 0),
  acceleration = vec3(0, 0, 0),
  angular_acceleration = vec3(0, 0, 0),
}

M.force = 10
M.ang_force = 100
M.debug = false
M.lerp_factor = 20.0

local function predict(dt)
  M.target_transform.velocity = M.received_transform.velocity + M.received_transform.acceleration * M.received_transform.time_past
  M.target_transform.position = lerp(M.target_transform.position, M.received_transform.position + M.target_transform.velocity * M.received_transform.time_past, clamp(M.lerp_factor * dt, 0.00001, 1))

  --M.target_transform.angular_velocity = M.received_transform.angular_velocity + M.received_transform.angular_acceleration * M.received_transform.time_past
  --local rotation_delta = M.target_transform.angular_velocity * M.received_transform.time_past
  M.target_transform.rotation = quat(M.received_transform.rotation)-- * quatFromEuler(rotation_delta.x, rotation_delta.y, rotation_delta.z)
end

local function try_rude()
  if (M.target_transform.position - vec3(obj:getPosition())):length() > 7 then
    local p = M.target_transform.position
    obj:queueGameEngineLua("be:getObjectByID("..obj:getID().."):setPosition(Point3F("..p.x..", "..p.y..", "..p.z.."))")
  end
  --if quat(obj:getRotation()):distance(M.target_transform.rotation) > 1.5 then
  --  local p = M.target_transform.position
  --  local r = M.target_transform.rotation
  --  obj:queueGameEngineLua("be:getObjectByID("..obj:getID().."):setPositionRotation("..p.x..", "..p.y..", "..p.z..", "..r.x..", "..r.y..", "..r.z..", "..r.w..")")
  --end
end

local function draw_debug()
  obj.debugDrawProxy:drawSphere(0.3, M.target_transform.position:toFloat3(), color(0,255,0,100))
  obj.debugDrawProxy:drawSphere(0.3, M.received_transform.position:toFloat3(), color(0,0,255,100))
end

local function update(dt)
  if dt > 0.15 then return end
  M.received_transform.time_past = clamp(M.received_transform.time_past + dt, 0, 0.5)
  predict(dt)
  try_rude()

  if M.debug then
    draw_debug()
  end
 
  local force = M.force
  local ang_force = M.ang_force

  local c_ang = -math.sqrt(4 * ang_force)

  local velocity_difference = M.target_transform.velocity - vec3(obj:getVelocity())
  local position_delta = M.target_transform.position - vec3(obj:getPosition())
  --position_delta = position_delta:normalized() * math.pow(position_delta:length(), 2)
  local linear_force = (velocity_difference + position_delta * force) * dt * 5
  if linear_force:length() > 10 then
    linear_force = linear_force:normalized() * 10
  end
 
  local local_ang_vel = vec3(
    obj:getYawAngularVelocity(),
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity()
  )

  local angular_velocity_difference = M.target_transform.angular_velocity - local_ang_vel
  local angle_delta = M.target_transform.rotation / quat(obj:getRotation())
  local angular_force = angle_delta:toEulerYXZ()
  local angular_force = (angular_velocity_difference + angular_force * ang_force + c_ang * local_ang_vel) * dt
  if angular_force:length() > 25 then
    return
  end

  if angular_force:length() > 0.1 then
    kiss_vehicle.apply_linear_velocity_ang_torque(
      linear_force.x,
      linear_force.y,
      linear_force.z,
      angular_force.y,
      angular_force.z,
      angular_force.x
    )
  elseif linear_force:length() > 0.1 then
    kiss_vehicle.apply_linear_velocity(
      linear_force.x,
      linear_force.y,
      linear_force.z
    )
  end
end

local function set_target_transform(raw)
  local transform = jsonDecode(raw)
  local time_dif = clamp((transform.sent_at - M.received_transform.sent_at), 0.01, 0.1)

  M.received_transform.acceleration = (vec3(transform.velocity) - M.received_transform.velocity) / time_dif
  if M.received_transform.acceleration:length() > 5 then
    M.received_transform.acceleration = M.received_transform.acceleration:normalized() * 5
  end
  M.received_transform.angular_acceleration = (vec3(transform.angular_velocity) - M.received_transform.angular_velocity) / time_dif
  if M.received_transform.acceleration:length() > 5 then
    M.received_transform.angular_acceleration = M.received_transform.angular_acceleration:normalized() * 5
  end
  M.received_transform.position = vec3(transform.position)
  M.received_transform.rotation = quat(transform.rotation)
  M.received_transform.velocity = vec3(transform.velocity)
  M.received_transform.angular_velocity = vec3(transform.angular_velocity)
  M.received_transform.time_past = transform.time_past
end

M.set_target_transform = set_target_transform
M.update = update

return M
