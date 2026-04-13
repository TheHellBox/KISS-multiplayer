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

local function update(dt, skip_rude, ang_scale, hitch_node_id, truck_mass)
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if dt > 0.1 then return end
  M.received_transform.time_past = clamp(M.received_transform.time_past + dt, 0, 0.5)
  predict(dt)
  -- Coupled trucks skip try_rude (6m teleport yanks the whole rig under
  -- trailer drag lag). Angular torque is skipped separately below via the
  -- forced ang_skipped flag, so coupled trucks fall through to the
  -- linear-only propulsion branch — which is what actually moves a ghost
  -- vehicle at all (input sync doesn't produce real engine thrust on a
  -- non-owned vehicle).
  if not skip_rude and try_rude() then return end

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
  -- Coupled trucks: scale PD forces by two factors that multiply together.
  --
  -- 1. Mass ratio (ang_scale): truck_mass / (truck_mass + trailer_mass),
  --    clamped [0.05, 0.5]. Heavier rigs get softer PD so the force
  --    transmitted through the hitch doesn't exceed trailer beam budgets.
  --
  -- 2. Ping / data staleness: the older the received transform data, the
  --    larger the position delta the PD chases, and the more likely the
  --    correction overshoots (the target is where the owner WAS, not
  --    where they ARE). Scale gain inversely with staleness so high-ping
  --    clients get softer corrections automatically. On LAN (~20ms
  --    staleness) the scale is ~1.0; at 200ms it drops to ~0.3.
  --    Applied to ALL vehicles (not just coupled) because overshooting
  --    hurts responsiveness for solo ghosts too, just less visibly.
  local staleness = M.received_transform.time_past
  local ping_scale = clamp(0.03 / math.max(staleness, 0.001), 0.3, 1.0)
  linear_force = linear_force * ping_scale
  if skip_rude and ang_scale then
    linear_force = linear_force * ang_scale
  end

  local local_ang_vel = vec3(
    obj:getYawAngularVelocity(),
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity()
  )

  local angular_velocity_difference = M.target_transform.angular_velocity - local_ang_vel
  local angle_delta = M.target_transform.rotation / quat(obj:getRotation())
  local angle_delta_euler = angle_delta:toEulerYXZ()
  local angular_force
  if skip_rude then
    -- Coupled truck: yaw-only proportional correction, pivoted around the
    -- hitch node via the pivot arg to apply_linear_velocity_ang_torque.
    --
    -- Axis: compute the yaw error from forward-vectors projected onto the
    -- horizontal plane, then convert back to a world-up angular velocity.
    -- Using angle_delta_euler.x directly was unreliable — toEulerYXZ's
    -- component order is ambiguous for our local convention, and even a
    -- small bleed into roll/pitch feeds energy into the chain that
    -- accumulates until something flips. Forward-vector math is
    -- unambiguous: pure yaw, nothing else.
    local target_rot = M.target_transform.rotation
    local cur_rot = quat(obj:getRotation())
    local target_fwd = target_rot * vec3(0, 1, 0)
    local cur_fwd = cur_rot * vec3(0, 1, 0)
    target_fwd.z = 0
    cur_fwd.z = 0
    local tlen = target_fwd:length()
    local clen = cur_fwd:length()
    local yaw_err = 0
    if tlen > 0.01 and clen > 0.01 then
      target_fwd = target_fwd * (1 / tlen)
      cur_fwd = cur_fwd * (1 / clen)
      local cross = cur_fwd:cross(target_fwd)
      yaw_err = math.asin(clamp(cross.z, -1, 1))
    end
    -- Gain combines two scales:
    --   * Speed-inverse: KE grows with v², so soften with speed to keep
    --     per-tick rotation energy bounded.
    --   * Mass-linear: the same gain over-rotates a light rig (car+tilt)
    --     because its moment of inertia is much smaller than a heavy
    --     tractor. Scale linearly with truck mass around a 5000 kg
    --     reference, clamped so extreme rigs don't blow up.
    local speed = vec3(obj:getVelocity()):length()
    local mass_factor = clamp((truck_mass or 5000) / 5000, 0.3, 2.0)
    local coupled_ang_force = 2.0 * mass_factor / (1.0 + speed / 5.0)
    -- Yaw value goes in the x slot to match local_ang_vel convention
    -- (vec3(yaw, pitch, roll)), since apply_linear_velocity_ang_torque
    -- reads angular_force.x as the yaw argument.
    local yaw_term = vec3(yaw_err * coupled_ang_force, 0, 0)
    angular_force = (angular_velocity_difference + yaw_term + c_ang * local_ang_vel) * dt * ping_scale
    -- Hard cap, tightened from 3 → 1 now that per-node forces scale with
    -- distance from the hitch pivot (can be ~2x longer arm than CG pivot).
    if angular_force:length() > 1 then
      angular_force = angular_force:normalized() * 1
    end
  else
    angular_force = (angular_velocity_difference + angle_delta_euler * ang_force + c_ang * local_ang_vel) * dt
  end

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
      angular_force.x,
      hitch_node_id  -- nil for non-coupled, the truck-side hitch node otherwise
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
      obj:getID(), time_dif, transform.time_past or 0,
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

-- Constraint-preserving sync for coupled trailers.
-- The expected trailer CG is computed on the GE side (branching by hitch
-- type: fifth wheel = yaw only, ball/pintle hitch = full quaternion).
-- Here we only check for drift and hard-snap when it exceeds the threshold.
-- Between snaps the trailer runs entirely on BeamNG's own coupler physics.

-- Per-hitch-type drift thresholds
local DRIFT_THRESHOLDS = {
  fifthwheel = { pos = 0.25, ticks = 15 },  -- tight: plate constrains well
  ball       = { pos = 0.25, ticks = 15 },  -- standard ball hitch
  pintle     = { pos = 0.45, ticks = 15 },  -- loose: designed-in slop
}
local DEFAULT_THRESHOLD = DRIFT_THRESHOLDS.ball

local STALENESS_CUTOFF = 0.5  -- seconds — suspend sync if data is older
local snap_cooldown_ticks = 0

local function update_coupled(dt, data_raw)
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if dt > 0.1 then return end

  -- Staleness: if transform data is too old, let physics run freely
  if M.received_transform.time_past > STALENESS_CUTOFF then
    if M.debug_log then
      print(string.format(
        "[KISS_COUPLED id=%d] STALE data (%.3fs), skipping sync",
        obj:getID(), M.received_transform.time_past
      ))
    end
    return
  end

  -- Snap cooldown: let coupler re-equilibrate after a snap
  if snap_cooldown_ticks > 0 then
    snap_cooldown_ticks = snap_cooldown_ticks - 1
    return
  end

  local data = jsonDecode(data_raw)
  local expected_pos = vec3(data.expected_pos)
  local kingpin_world = vec3(data.kingpin_world)
  local cur_pos = vec3(obj:getPosition())
  local hitch_type = data.hitch_type or "ball"
  local thresholds = DRIFT_THRESHOLDS[hitch_type] or DEFAULT_THRESHOLD

  -- Measure drift between expected and actual trailer CG
  local pos_drift = expected_pos:distance(cur_pos)

  -- Debug visualization
  if M.debug then
    local within_threshold = pos_drift <= thresholds.pos
    -- Expected position: green if OK, red if drifted
    if within_threshold then
      obj.debugDrawProxy:drawSphere(0.3, expected_pos:toFloat3(), color(0,255,0,100))
    else
      obj.debugDrawProxy:drawSphere(0.3, expected_pos:toFloat3(), color(255,0,0,200))
    end
    -- Actual position
    obj.debugDrawProxy:drawSphere(0.15, cur_pos:toFloat3(), color(255,255,0,100))
    -- Drift line: current -> expected
    obj.debugDrawProxy:drawCylinder(cur_pos:toFloat3(), expected_pos:toFloat3(), 0.03, color(255,255,255,180))
    -- Kingpin/hitch point marker
    obj.debugDrawProxy:drawSphere(0.1, kingpin_world:toFloat3(), color(0,200,255,200))
    -- Coupled mode indicator: orange=fifthwheel, magenta=ball, cyan=pintle
    local coupled_marker = cur_pos + vec3(0, 0, 2)
    if hitch_type == "fifthwheel" then
      obj.debugDrawProxy:drawSphere(0.25, coupled_marker:toFloat3(), color(255,165,0,200))
    elseif hitch_type == "pintle" then
      obj.debugDrawProxy:drawSphere(0.25, coupled_marker:toFloat3(), color(0,200,255,200))
    else
      obj.debugDrawProxy:drawSphere(0.25, coupled_marker:toFloat3(), color(255,0,255,200))
    end
  end

  if M.debug_log then
    local snapping = pos_drift > thresholds.pos
    print(string.format(
      "[KISS_COUPLED id=%d] type=%s pos_drift=%.3f thresh=%.2f%s",
      obj:getID(), hitch_type, pos_drift, thresholds.pos,
      snapping and " [SNAP]" or ""
    ))
  end

  -- Never teleport a coupled trailer. Let the physics coupler constraint
  -- drive it off the truck; drift is expected and tolerable.
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
