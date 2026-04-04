local M = {}
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
M.debug = true
M.debug_log = true
M.lerp_factor = 30.0

-- Debug: last computed forces for visualization
local last_linear_force = vec3(0, 0, 0)
local last_angular_force = vec3(0, 0, 0)
local last_position_delta = vec3(0, 0, 0)
local last_velocity_diff = vec3(0, 0, 0)
local last_update_skipped = false
local log_timer = 0
local LOG_INTERVAL = 1.0 / 33.0 -- log every tick (~30ms)

local function predict(dt)
  M.target_transform.velocity = M.received_transform.velocity + M.received_transform.acceleration * M.received_transform.time_past
  local distance =  M.target_transform.position:distance(vec3(obj:getPosition()))
  local p = M.received_transform.position + M.target_transform.velocity * M.received_transform.time_past
  if distance < 2 then
    M.target_transform.position = lerp(M.target_transform.position, p, clamp(M.lerp_factor * dt, 0.00001, 1))
  else
    M.target_transform.position = p
  end

  --M.target_transform.angular_velocity = M.received_transform.angular_velocity + M.received_transform.angular_acceleration * M.received_transform.time_past
  --local rotation_delta = M.target_transform.angular_velocity * M.received_transform.time_past
  M.target_transform.rotation = quat(M.received_transform.rotation)-- * quatFromEuler(rotation_delta.x, rotation_delta.y, rotation_delta.z)
end

local function try_rude()
  local distance =  M.target_transform.position:distance(vec3(obj:getPosition()))
  if distance > 6 then
    local p = M.target_transform.position
    obj:queueGameEngineLua("be:getObjectByID("..obj:getID().."):setPositionNoPhysicsReset(Point3F("..p.x..", "..p.y..", "..p.z.."))")
    return true
  end
  return false
end

local function draw_debug()
  local cur_pos = vec3(obj:getPosition())
  local target_pos = M.target_transform.position
  local received_pos = M.received_transform.position

  -- Position markers
  obj.debugDrawProxy:drawSphere(0.3, target_pos:toFloat3(), color(0,255,0,100))       -- green = predicted target
  obj.debugDrawProxy:drawSphere(0.3, received_pos:toFloat3(), color(0,0,255,100))      -- blue = last received from network
  obj.debugDrawProxy:drawSphere(0.15, cur_pos:toFloat3(), color(255,255,0,100))        -- yellow = actual current position

  -- Position error line: current → target (white)
  obj.debugDrawProxy:drawCylinder(cur_pos:toFloat3(), target_pos:toFloat3(), 0.03, color(255,255,255,180))

  -- Linear force vector (red) — scaled up 2x for visibility
  local force_end = cur_pos + last_linear_force * 2
  obj.debugDrawProxy:drawCylinder(cur_pos:toFloat3(), force_end:toFloat3(), 0.05, color(255,0,0,200))

  -- Velocity difference vector (cyan) — scaled up for visibility
  local vel_end = cur_pos + last_velocity_diff
  obj.debugDrawProxy:drawCylinder(cur_pos:toFloat3(), vel_end:toFloat3(), 0.03, color(0,255,255,150))

  -- Target velocity vector (magenta)
  local tvel_end = cur_pos + M.target_transform.velocity * 0.5
  obj.debugDrawProxy:drawCylinder(cur_pos:toFloat3(), tvel_end:toFloat3(), 0.02, color(255,0,255,120))

  -- Angular force indicator: draw a small offset sphere colored by angular force magnitude
  local ang_mag = last_angular_force:length()
  local ang_color_r = math.min(255, ang_mag * 50)
  local ang_color_g = math.max(0, 255 - ang_mag * 50)
  local ang_marker = cur_pos + vec3(0, 0, 1.5)
  obj.debugDrawProxy:drawSphere(0.15 + ang_mag * 0.05, ang_marker:toFloat3(), color(ang_color_r, ang_color_g, 0, 180))

  -- If update was skipped (angular force > 25), draw a big red X marker
  if last_update_skipped then
    local warn_pos = cur_pos + vec3(0, 0, 2.5)
    obj.debugDrawProxy:drawSphere(0.5, warn_pos:toFloat3(), color(255, 0, 0, 255))
  end
end

local function debug_log(dt, linear_force, angular_force, position_delta, velocity_diff, ang_vel_diff, angle_delta, skipped)
  log_timer = log_timer + dt
  if log_timer < LOG_INTERVAL then return end
  log_timer = log_timer - LOG_INTERVAL

  local pos_err = position_delta:length()
  local vel_err = velocity_diff:length()
  local lin_mag = linear_force:length()
  local ang_mag = angular_force:length()
  local ang_vel_err = ang_vel_diff:length()
  local angle_err = angle_delta:length()
  local time_past = M.received_transform.time_past
  local accel_mag = M.received_transform.acceleration:length()
  local ang_accel_mag = M.received_transform.angular_acceleration:length()

  local status = ""
  if skipped then status = " [SKIPPED: ang_force > 25]" end
  if pos_err > 6 then status = status .. " [TELEPORT]" end
  if lin_mag >= 10 then status = status .. " [LIN_CLAMPED]" end

  print(string.format(
    "[KISS_SYNC id=%d] pos_err=%.3f vel_err=%.3f lin_force=%.3f ang_force=%.3f | ang_vel_err=%.3f angle_err=%.3f | accel=%.3f ang_accel=%.3f | time_past=%.4f%s",
    obj:getID(), pos_err, vel_err, lin_mag, ang_mag, ang_vel_err, angle_err, accel_mag, ang_accel_mag, time_past, status
  ))
end

local function update(dt)
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if dt > 0.1 then return end
  M.received_transform.time_past = clamp(M.received_transform.time_past + dt, 0, 0.5)
  predict(dt)
  if try_rude() then return end

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
  local angle_delta_euler = angle_delta:toEulerYXZ()
  local angular_force = (angular_velocity_difference + angle_delta_euler * ang_force + c_ang * local_ang_vel) * dt

  -- Store debug state
  last_linear_force = linear_force
  last_position_delta = position_delta
  last_velocity_diff = velocity_difference

  local ang_skipped = angular_force:length() > 25

  -- Store debug state
  last_angular_force = angular_force
  last_update_skipped = ang_skipped

  if M.debug then draw_debug() end
  if M.debug_log then debug_log(dt, linear_force, angular_force, position_delta, velocity_difference, angular_velocity_difference, angle_delta_euler, ang_skipped) end

  if not ang_skipped and angular_force:length() > 0.1 then
    kiss_vehicle.apply_linear_velocity_ang_torque(
      linear_force.x,
      linear_force.y,
      linear_force.z,
      angular_force.y,
      angular_force.z,
      angular_force.x
    )
  elseif linear_force:length() > (dt * 15) then
    -- Still apply linear forces even when angular is too high
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
  local raw_accel = M.received_transform.acceleration:length()
  if M.received_transform.acceleration:length() > 5 then
    M.received_transform.acceleration = M.received_transform.acceleration:normalized() * 5
  end
  M.received_transform.angular_acceleration = (vec3(transform.angular_velocity) - M.received_transform.angular_velocity) / time_dif
  local raw_ang_accel = M.received_transform.angular_acceleration:length()
  -- BUG: this was checking acceleration instead of angular_acceleration, so angular accel was never clamped
  if M.received_transform.angular_acceleration:length() > 5 then
    M.received_transform.angular_acceleration = M.received_transform.angular_acceleration:normalized() * 5
  end

  if M.debug_log then
    local accel_clamped = raw_accel > 5
    local ang_accel_clamped = raw_ang_accel > 5
    local flags = ""
    if accel_clamped then flags = flags .. " [ACCEL_CLAMPED from " .. string.format("%.2f", raw_accel) .. "]" end
    if ang_accel_clamped then flags = flags .. " [ANG_ACCEL_CLAMPED from " .. string.format("%.2f", raw_ang_accel) .. "]" end
    print(string.format(
      "[KISS_RECV id=%d] time_dif=%.4f time_past=%.4f vel=(%.2f,%.2f,%.2f) ang_vel=(%.2f,%.2f,%.2f)%s",
      obj:getID(), time_dif, transform.time_past,
      transform.velocity[1], transform.velocity[2], transform.velocity[3],
      transform.angular_velocity[1], transform.angular_velocity[2], transform.angular_velocity[3],
      flags
    ))
  end

  M.received_transform.position = vec3(transform.position)
  M.received_transform.rotation = quat(transform.rotation)
  M.received_transform.velocity = vec3(transform.velocity)
  M.received_transform.angular_velocity = vec3(transform.angular_velocity)
  M.received_transform.time_past = transform.time_past
end

-- Coupled vehicle sync: only correct the hitch angle, no position forces.
-- The coupler constraint handles positioning; we just nudge the swing angle.
local function update_coupled(dt, truck_target_rot_raw, truck_local_rot_raw)
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if dt > 0.1 then return end

  local truck_target_rot = quat(jsonDecode(truck_target_rot_raw))
  local truck_local_rot = quat(jsonDecode(truck_local_rot_raw))
  local trailer_local_rot = quat(obj:getRotation())

  -- Use received_transform directly (predict() doesn't run for coupled vehicles)
  local trailer_target_rot = M.received_transform.rotation

  -- Target relative angle: how the trailer should be angled vs the truck (from owner's data)
  local target_relative = trailer_target_rot * truck_target_rot:inversed()
  -- Current relative angle: how the trailer is actually angled vs the truck locally
  local current_relative = trailer_local_rot * truck_local_rot:inversed()
  -- Correction: rotate from current relative to target relative
  local correction = target_relative * current_relative:inversed()
  local correction_euler = correction:toEulerYXZ()

  -- Scale forces by mass so heavier trailers get proportionally more force
  local mass_scale = obj:getTotalMass() / 20000
  local ang_force_strength = 5 * mass_scale
  local angular_force = correction_euler * ang_force_strength * dt

  -- Clamp to prevent explosions
  if angular_force:length() > 15 then
    angular_force = angular_force:normalized() * 15
  end

  -- Debug visualization for coupled vehicles
  if M.debug then
    local cur_pos = vec3(obj:getPosition())
    local target_pos = M.received_transform.position
    obj.debugDrawProxy:drawSphere(0.3, target_pos:toFloat3(), color(0,255,0,100))
    obj.debugDrawProxy:drawSphere(0.15, cur_pos:toFloat3(), color(255,255,0,100))
    obj.debugDrawProxy:drawCylinder(cur_pos:toFloat3(), target_pos:toFloat3(), 0.03, color(255,255,255,180))
    -- Orange sphere above = coupled mode indicator
    local coupled_marker = cur_pos + vec3(0, 0, 2)
    obj.debugDrawProxy:drawSphere(0.25, coupled_marker:toFloat3(), color(255,165,0,200))
    -- Angular correction magnitude
    local ang_mag = angular_force:length()
    local ang_marker = cur_pos + vec3(0, 0, 1.5)
    local ang_color_r = math.min(255, ang_mag * 50)
    local ang_color_g = math.max(0, 255 - ang_mag * 50)
    obj.debugDrawProxy:drawSphere(0.15 + ang_mag * 0.05, ang_marker:toFloat3(), color(ang_color_r, ang_color_g, 0, 180))
  end

  if M.debug_log then
    local angle_err = correction_euler:length()
    local ang_mag = angular_force:length()
    local pos_err = M.received_transform.position:distance(vec3(obj:getPosition()))
    print(string.format(
      "[KISS_COUPLED id=%d] pos_drift=%.3f angle_err=%.3f ang_force=%.3f correction=(%.3f,%.3f,%.3f)",
      obj:getID(), pos_err, angle_err, ang_mag, correction_euler.x, correction_euler.y, correction_euler.z
    ))
  end

  -- Gentle linear nudge to help the coupler keep up — the coupler constraint alone
  -- can't effectively transfer PD velocity impulses from the truck
  local pos_delta = M.received_transform.position - vec3(obj:getPosition())
  local linear_force = pos_delta * 0.5 * mass_scale * dt
  if linear_force:length() > 1.0 * mass_scale then
    linear_force = linear_force:normalized() * 1.0 * mass_scale
  end

  if angular_force:length() > 0.05 or linear_force:length() > (dt * 5) then
    kiss_vehicle.apply_linear_velocity_ang_torque(
      linear_force.x,
      linear_force.y,
      linear_force.z,
      angular_force.y,
      angular_force.z,
      angular_force.x
    )
  end
end

local function onExtensionLoaded()
  M.received_transform.position = vec3(obj:getPosition())
  M.target_transform.position = vec3(obj:getPosition())
  M.received_transform.rotation = quat(obj:getRotation())
  M.target_transform.rotation = quat(obj:getRotation())
  cooldown_timer = 1.5
end

local function onReset()
  cooldown_timer = 0.2
end

M.set_target_transform = set_target_transform
M.update = update
M.update_coupled = update_coupled
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset

return M
