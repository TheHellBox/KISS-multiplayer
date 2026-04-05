local M = {}

local string_buffer = require("string.buffer")

local cooldown_timer = 2

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

M.force = 3
M.ang_force = 100
M.debug = false
M.lerp_factor = 30.0

local object_position = vec3()
local object_velocity = vec3()
local object_rotation = quat()

local predicted_position = vec3()
local function predict(dt)
  -- M.target_transform.velocity = M.received_transform.velocity + M.received_transform.acceleration * M.received_transform.time_past
  local target_velocity = M.target_transform.velocity
  target_velocity:setScaled2(M.received_transform.acceleration, M.received_transform.time_past)
  target_velocity:setAdd(M.received_transform.velocity)

  local distance = M.target_transform.position:squaredDistance(object_position)

  -- predicted_position = M.received_transform.position + M.target_transform.velocity, M.received_transform.time_past
  predicted_position:setScaled2(M.target_transform.velocity, M.received_transform.time_past)
  predicted_position:setAdd(M.received_transform.position)
  if distance < 2 * 2 then
    M.target_transform.position:setLerp(M.target_transform.position, predicted_position, clamp(M.lerp_factor * dt, 0.00001, 1))
  else
    M.target_transform.position:set(predicted_position)
  end

  --M.target_transform.angular_velocity = M.received_transform.angular_velocity + M.received_transform.angular_acceleration * M.received_transform.time_past
  --local rotation_delta = M.target_transform.angular_velocity * M.received_transform.time_past
  M.target_transform.rotation:set(M.received_transform.rotation)-- * quatFromEuler(rotation_delta.x, rotation_delta.y, rotation_delta.z)
end

local function try_rude()
  local distance = M.target_transform.position:squaredDistance(object_position)
  if distance > 6 * 6 then
    local p = M.target_transform.position
    obj:queueGameEngineLua("getObjectByID("..objectId.."):setPositionNoPhysicsReset(vec3("..p.x..", "..p.y..", "..p.z.."))")
    return true
  end
  return false
end

local function draw_debug()
  obj.debugDrawProxy:drawSphere(0.3, M.target_transform.position:toFloat3(), color(0,255,0,100))
  obj.debugDrawProxy:drawSphere(0.3, M.received_transform.position:toFloat3(), color(0,0,255,100))
end

local velocity_difference = vec3()
local position_delta = vec3()
local linear_force = vec3()
local local_ang_vel = vec3()
local angular_velocity_difference = vec3()
local angle_delta = quat()
local angular_force = vec3()
local scaled_ang_vel = vec3()

local function update(dt)
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if dt > 0.1 or not M.received_transform.time_past then return end
  object_position:set(obj:getPositionXYZ())
  object_rotation:set(obj:getRotation())
  object_velocity:set(obj:getVelocityXYZ())

  M.received_transform.time_past = clamp(M.received_transform.time_past + dt, 0, 0.5)
  predict(dt)
  if try_rude() then return end

  if M.debug then
    draw_debug()
  end

  local force = M.force
  local ang_force = M.ang_force

  local c_ang = -math.sqrt(4 * ang_force)

  velocity_difference:setSub2(M.target_transform.velocity, object_velocity)
  position_delta:setSub2(M.target_transform.position, object_position)

  -- linear_force = (velocity_difference + position_delta * force) * dt * 5
  linear_force:setScaled2(position_delta, force)
  linear_force:setAdd(velocity_difference)
  linear_force:setScaled(dt * 5)
  if linear_force:squaredLength() > 10 * 10 then
    linear_force:normalize()
    linear_force:setScaled(10)
  end

  local_ang_vel:set(
    obj:getYawAngularVelocity(),
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity()
  )

  angular_velocity_difference:setSub2(M.target_transform.angular_velocity, local_ang_vel)
  angle_delta:setMulInv2(M.target_transform.rotation, object_rotation)
  angular_force:set(angle_delta:toEulerYXZ())

  -- angular_force = (angular_velocity_difference + (angular_force * ang_force) + (c_ang * local_ang_vel)) * dt
  angular_force:setScaled(ang_force)
  scaled_ang_vel:setScaled2(local_ang_vel, c_ang)
  angular_force:setAdd(scaled_ang_vel)
  angular_force:setAdd(angular_velocity_difference)
  angular_force:setScaled(dt)

  if angular_force:squaredLength() > 25 * 25 then
    return
  end

  if angular_force:squaredLength() > 0.1 * 0.1 then
    kiss_vehicle.apply_linear_velocity_ang_torque(
      linear_force.x,
      linear_force.y,
      linear_force.z,
      angular_force.y,
      angular_force.z,
      angular_force.x
    )
  elseif linear_force:squaredLength() > (dt * 15) * (dt * 15) then
    kiss_vehicle.apply_linear_velocity(
      linear_force.x,
      linear_force.y,
      linear_force.z
    )
  end
end

local transform_velocity = vec3()
local transform_angular_velocity = vec3()
local function set_target_transform(buffer_data)
  local transform = string_buffer.decode(buffer_data)
  local time_dif = clamp((transform.sent_at - M.received_transform.sent_at), 0.01, 0.1)

  transform_velocity:set(transform.velocity[1], transform.velocity[2], transform.velocity[3])
  transform_angular_velocity:set(transform.angular_velocity[1], transform.angular_velocity[2], transform.angular_velocity[3])

  local acceleration = M.received_transform.acceleration
  acceleration:setSub2(transform_velocity, M.received_transform.velocity)
  acceleration:setScaled(1 / time_dif)
  if acceleration:squaredLength() > 5 * 5 then
    acceleration:normalize()
    acceleration:setScaled(5)
  end

  local angular_acceleration = M.received_transform.angular_acceleration
  angular_acceleration:setSub2(transform_angular_velocity, M.received_transform.angular_velocity)
  angular_acceleration:setScaled(1 / time_dif)
  if angular_acceleration:squaredLength() > 5 * 5 then
    angular_acceleration:normalize()
    angular_acceleration:setScaled(5)
  end

  M.received_transform.position:set(transform.position[1], transform.position[2], transform.position[3])
  M.received_transform.rotation:set(transform.rotation[1], transform.rotation[2], transform.rotation[3], transform.rotation[4])
  M.received_transform.velocity:set(transform_velocity)
  M.received_transform.angular_velocity:set(transform_angular_velocity)
  M.received_transform.time_past = transform.time_past
end

local function onExtensionLoaded()
  object_position:set(obj:getPositionXYZ())
  object_rotation:set(obj:getRotation())
  M.received_transform.position:set(object_position)
  M.target_transform.position:set(object_position)
  M.received_transform.rotation:set(object_rotation)
  M.target_transform.rotation:set(object_rotation)
  cooldown_timer = 1.5
end

local function onReset()
  cooldown_timer = 0.2
end

M.set_target_transform = set_target_transform
M.update = update
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset

return M
