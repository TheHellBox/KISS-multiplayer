-- KissMP Transforms - COG-space cluster replay.

local M = {}

M.debug = false
M.cooldown_timer = 2
M.sync_id = nil
M.ownership = true
M.ownership_known = false

-- Overshoot dampener state for the PD loop in update(). Tracks the previous
-- frame's requested correction and the current observed velocity delta; if
-- the body didn't deliver what we asked for last frame and the current
-- requested correction is in the same direction as the failure, the dampener
-- scales it down. Without this, when local physics can't keep up (saturated
-- tires, torque-limited drive, soft-body lag) the loop keeps pushing harder
-- and oscillates.
M.last_linear_step = nil
M.last_angular_step = nil
M.last_cog_velocity = nil
M.last_body_angular_velocity = nil
M.smooth_local_refnode_velocity = nil
M.smooth_local_body_angular_velocity = nil
M.smooth_linear_step_error = nil
M.smooth_angular_step_error = nil
M.last_update_dt = 0
M.linear_pull_scale = 1.0
M.angular_pull_scale = 0.65

local MAX_LINEAR_STEP_ERROR = 3
local MAX_ANGULAR_STEP_ERROR = 3
local LOCAL_SMOOTH_RATE = 50.0
local ERROR_SMOOTH_RATE = 50.0

-- Mass-weighted COG offset, body frame. Wrong COG injects phantom pos/vel
-- error during turns (proportional to rotation/angular-velocity mismatch),
-- which the PD loop and try_rude both chase as oscillation. The mass-
-- weighted variant tracks mass distribution rather than the geometric
-- support-pair midpoint.
local function get_cog_body()
  if kiss_vehicle and kiss_vehicle.get_sync_cog_body then
    return kiss_vehicle.get_sync_cog_body()
  end
  return vec3(0, 0, 0)
end

local function get_primary_refnode_cid()
  local refs = v and v.data and v.data.refNodes
  if type(refs) ~= "table" then return nil end
  local entry = refs[0] or refs[1] or refs
  local ref = entry and (entry.cidRef or entry.idRef or entry.ref) or nil
  if type(ref) == "number" then return ref end
  if type(ref) == "string" and beamstate and beamstate.nodeNameMap then
    return beamstate.nodeNameMap[ref]
  end
  return nil
end

local function get_local_sync_time()
  return obj:getSimTime() or os.clock()
end

local function wrap_angle_pi(angle)
  while angle > math.pi do angle = angle - (2 * math.pi) end
  while angle < -math.pi do angle = angle + (2 * math.pi) end
  return angle
end

local function clear_drift_state()
  M.last_linear_step = nil
  M.last_angular_step = nil
  M.last_cog_velocity = nil
  M.last_body_angular_velocity = nil
  M.smooth_local_refnode_velocity = nil
  M.smooth_local_body_angular_velocity = nil
  M.smooth_linear_step_error = nil
  M.smooth_angular_step_error = nil
  M.last_update_dt = 0
end

local function lowpass_vec(prev, target, dt, rate)
  if not prev then
    return vec3(target.x, target.y, target.z)
  end
  local alpha = math.min(math.max(dt, 0) * rate, 1.0)
  return vec3(
    prev.x + (target.x - prev.x) * alpha,
    prev.y + (target.y - prev.y) * alpha,
    prev.z + (target.z - prev.z) * alpha
  )
end

local ClusterServo = {}

function ClusterServo:limit_step(step, max_len)
  local len = step:length()
  if len > max_len then
    return step * (max_len / len)
  end
  return step
end

local function apply_disconnected_counterforce(cog_offset_world, linear_step, angular_step)
  if not (kiss_vehicle and kiss_vehicle.get_disconnected_node_states) then return end
  local disconnected = kiss_vehicle.get_disconnected_node_states()
  if #disconnected == 0 then return end

  local pfps = obj:getPhysicsFPS() or 2000
  local x, y, z = -linear_step.x, -linear_step.y, -linear_step.z
  local pitch, roll, yaw = -angular_step.x, -angular_step.y, -angular_step.z
  local force = float3(0, 0, 0)

  for _, state in ipairs(disconnected) do
    local cid = state.cid
    local mass = state.mass or obj:getNodeMass(cid) or 0
    if cid and mass > 0 then
      local node_pos = obj:getNodePosition(cid)
      local node_offset_x = node_pos.x - cog_offset_world.x
      local node_offset_y = node_pos.y - cog_offset_world.y
      local node_offset_z = node_pos.z - cog_offset_world.z
      force:set(
        (x + node_offset_y * yaw - node_offset_z * roll) * mass * pfps,
        (y + node_offset_z * pitch - node_offset_x * yaw) * mass * pfps,
        (z + node_offset_x * roll - node_offset_y * pitch) * mass * pfps
      )
      obj:applyForceVector(cid, force)
    end
  end
end

function ClusterServo:solve_step(cog_position_error, cog_velocity_error, orientation_error, spin_error, dt)
  local POS_CORRECT_MUL, POS_FORCE_MUL = 5, 5
  local MAX_POS_FORCE = 100
  local ROT_CORRECT_MUL, ROT_FORCE_MUL = 7, 7
  local MAX_ROT_FORCE = 50

  local linear_scale = math.min(POS_FORCE_MUL * dt, 1.0)
  local angular_scale = math.min(ROT_FORCE_MUL * dt, 1.0)

  local linear_step = (cog_velocity_error + cog_position_error * POS_CORRECT_MUL) * linear_scale * (M.linear_pull_scale or 1.0)
  local angular_step = (spin_error + orientation_error * ROT_CORRECT_MUL) * angular_scale * (M.angular_pull_scale or 1.0)

  return self:limit_step(linear_step, MAX_POS_FORCE * dt),
         self:limit_step(angular_step, MAX_ROT_FORCE * dt)
end

local function set_linear_pull_scale(scale)
  if type(scale) == "number" then
    M.linear_pull_scale = math.max(0.5, math.min(scale, 1.5))
  end
end

local function set_angular_pull_scale(scale)
  if type(scale) == "number" then
    M.angular_pull_scale = math.max(0.2, math.min(scale, 1.2))
  end
end

function ClusterServo:apply_cluster_step(refnode_cid, cog_offset_world, linear_step, angular_step, local_cog_speed)
  local MIN_POS_FORCE, MIN_ROT_FORCE = 0.04, 0.02
  local pfps = obj:getPhysicsFPS() or 2000

  if angular_step:length() > MIN_ROT_FORCE or local_cog_speed > 1 then
    local cog_cross_spin_x = cog_offset_world.y * angular_step.z - cog_offset_world.z * angular_step.y
    local cog_cross_spin_y = cog_offset_world.z * angular_step.x - cog_offset_world.x * angular_step.z
    local cog_cross_spin_z = cog_offset_world.x * angular_step.y - cog_offset_world.y * angular_step.x
    obj:applyClusterLinearAngularAccel(
      refnode_cid,
      vec3(
        (linear_step.x - cog_cross_spin_x) * pfps,
        (linear_step.y - cog_cross_spin_y) * pfps,
        (linear_step.z - cog_cross_spin_z) * pfps
      ),
      vec3(
        -angular_step.x * pfps,
        -angular_step.y * pfps,
        -angular_step.z * pfps
      )
    )
    apply_disconnected_counterforce(cog_offset_world, linear_step, angular_step)
  elseif linear_step:length() > MIN_POS_FORCE then
    obj:applyClusterLinearAngularAccel(
      refnode_cid,
      vec3(linear_step.x * pfps, linear_step.y * pfps, linear_step.z * pfps),
      vec3(0, 0, 0)
    )
    apply_disconnected_counterforce(cog_offset_world, linear_step, vec3(0, 0, 0))
  end
end

local function get_synced_transform(current_time)
  if not M.sync_id then return nil end
  return kiss_sync.update_and_get_transform(M.sync_id, current_time)
end

-- Handle large corrections (teleport prevention) in the same COG space used
-- by the active correction loop. The wire position is COG-anchored; the GE
-- cluster snap receives the equivalent refnode origin.
local function try_rude(target_cog_position, target_rotation, target_cog_velocity, target_angular_velocity, dt)
  -- Use the same rotation convention the wire / PD loop use (quatFromDir
  -- on negated direction vector). Mixing obj:getRotation() here would
  -- produce a frame-mismatched yaw error and fire the rude-snap at the
  -- wrong heading thresholds.
  local current_rotation = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local current_centroid_pos = vec3(obj:getPosition()) + current_rotation * get_cog_body()
  local current_euler = current_rotation:toEulerYXZ()
  local target_euler = target_rotation:toEulerYXZ()
  local planar_error_x = target_cog_position.x - current_centroid_pos.x
  local planar_error_y = target_cog_position.y - current_centroid_pos.y
  local planar_error = math.sqrt(planar_error_x * planar_error_x + planar_error_y * planar_error_y)
  local vertical_error = math.abs(target_cog_position.z - current_centroid_pos.z)
  local yaw_error = math.abs(wrap_angle_pi(target_euler.x - current_euler.x))

  local severe = planar_error > 8.0
    or vertical_error > 4.0
    or (planar_error > 5.0 and yaw_error > math.rad(45))

  if severe then
    M.rude_error_time = (M.rude_error_time or 0) + dt
  else
    M.rude_error_time = math.max(0, (M.rude_error_time or 0) - (dt * 2.0))
  end

  if (M.rude_error_time or 0) < 0.25 then
    return false
  end

  clear_drift_state()
  if M.sync_id and kiss_sync and kiss_sync.reset_motion_smoothers then
    kiss_sync.reset_motion_smoothers(M.sync_id)
  end
  M.rude_error_time = 0

  local target_cog_offset_world = target_rotation * get_cog_body()
  local target_origin = target_cog_position - target_cog_offset_world
  local target_angular_velocity_world = target_angular_velocity or vec3(0, 0, 0)
  local origin_velocity = (target_cog_velocity or vec3(0, 0, 0)) - target_cog_offset_world:cross(target_angular_velocity_world)
  obj:queueGameEngineLua(
    "kisstransform.apply_cluster_target("..obj:getID()..","
    ..target_origin.x..","..target_origin.y..","..target_origin.z..","
    ..target_rotation.x..","..target_rotation.y..","..target_rotation.z..","..target_rotation.w..","
    ..origin_velocity.x..","..origin_velocity.y..","..origin_velocity.z..")"
  )
  return true
end

local function draw_debug(synced_transform)
  obj.debugDrawProxy:drawSphere(0.3, synced_transform.position:toFloat3(), color(0,255,0,100))
  local current_pos = vec3(obj:getPosition())
  obj.debugDrawProxy:drawSphere(0.3, current_pos:toFloat3(), color(255,0,0,100))
  local blend_progress = kiss_sync.get_blend_progress(M.sync_id, M.last_update_time or 0)
  if blend_progress < 1.0 then
    obj.debugDrawProxy:drawText("Blend: " .. math.floor(blend_progress * 100) .. "%", current_pos:toFloat3(), color(255,255,0,255))
  end
end

local function update(dt)
  if not M.ownership_known or M.ownership then
    return
  end

  if M.debug and dt <= 0.1 then
    print("[kiss_transforms.update] obj=" .. tostring(obj) .. " id=" .. tostring(obj:getID()) .. " sync_id=" .. tostring(M.sync_id) .. " dt=" .. tostring(dt))
  end

  if M.cooldown_timer > 0 then
    M.cooldown_timer = M.cooldown_timer - clamp(dt, 0, 0.02)
    return
  end

  if dt > 0.1 then
    if M.debug then
      print("[kiss_transforms.update] BLOCKED by large dt: " .. dt)
    end
    return
  end

  local current_time = get_local_sync_time()
  M.last_update_time = current_time
  M.last_update_dt = dt

  if M.debug then
    print("[kiss_transforms.update] current_time=" .. current_time .. " calling get_synced_transform")
  end

  local synced_transform = get_synced_transform(current_time)

  if not synced_transform then
    if M.debug then
      print("[kiss_transforms.update] BLOCKED: get_synced_transform returned nil")
    end
    return
  end

  if M.debug then
    print("[kiss_transforms.update] Got synced_transform pos=(" .. synced_transform.position.x .. "," .. synced_transform.position.y .. "," .. synced_transform.position.z .. ")")
  end

  -- Owner-replay path: heading comes directly from the predicted owner body
  -- rotation; follower-side path error must never bias authoritative yaw.
  local target_cluster_rotation = synced_transform.rotation
  local target_cluster_angular_velocity = synced_transform.angular_velocity or vec3(0, 0, 0)
  local target_cog_position = synced_transform.position
  local target_cog_velocity = synced_transform.velocity or vec3(0, 0, 0)

  if try_rude(target_cog_position, target_cluster_rotation, target_cog_velocity, target_cluster_angular_velocity, dt) then
    if M.debug then
      print("[kiss_transforms.update] try_rude triggered - rude-snap reset applied")
      draw_debug(synced_transform)
    end
    return
  end

  -- PD-on-velocity correction.
  --
  -- We don't snap pose every frame; the cluster drifts to the target via
  -- per-frame force injection and the local physics solver integrates
  -- normally. Per-frame setClusterPosRelRot fights the solver's velocity-
  -- based integration and produces oscillation.
  --
  -- Control law (per axis, world frame, target velocity at COG):
  --   linear_step  = clamp((velocity_error + position_error * 5) * min(5*dt, 1), 100*dt)
  --   angular_step = clamp((spin_error     + rotation_error * 7) * min(7*dt, 1),  50*dt)
  -- Then the overshoot dampener scales each by linear_mul/angular_mul in [0, 1]
  -- depending on whether last frame's correction overshot.
  --
  -- Cluster API conventions:
  --   * Linear arg = (linear_step - cog x angular_step) * physicsFPS. The
  --     cross-product subtraction converts "Δv at COG" to the equivalent
  --     linear delta at refNode, so when the angular component rotates
  --     about refNode the COG ends up with the requested delta-v.
  --   * Angular arg is NEGATED: -angular_step * physicsFPS. The cluster
  --     API applies the angular argument with a sign flip internally;
  --     passing -delta produces +delta change in angular velocity.
  local refnode_cid = get_primary_refnode_cid()
  if refnode_cid then

    -- Wrong COG creates phantom position/velocity error proportional to
    -- rotation and angular-velocity mismatch.
    if kiss_vehicle and kiss_vehicle.maybe_recompute_sync_cog_body then
      kiss_vehicle.maybe_recompute_sync_cog_body()
    end
    local cog_body = vec3(0, 0, 0)
    if kiss_vehicle and kiss_vehicle.get_sync_cog_body then
      cog_body = kiss_vehicle.get_sync_cog_body()
    end

    -- Local state in world frame.
    local local_rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
    local cog_offset_world = cog_body:rotated(local_rot)
    local local_refnode_position = vec3(obj:getPosition())
    local local_motion = kiss_vehicle and kiss_vehicle.get_smoothed_local_motion and kiss_vehicle.get_smoothed_local_motion()
    local local_refnode_velocity = local_motion and local_motion.refnode_velocity
    local local_body_angular_velocity = local_motion and local_motion.body_omega
    if not local_refnode_velocity or not local_body_angular_velocity then
      local raw_local_refnode_velocity = vec3(obj:getVelocity())
      local raw_local_body_angular_velocity = vec3(
        obj:getPitchAngularVelocity(),
        obj:getRollAngularVelocity(),
        obj:getYawAngularVelocity()
      )
      M.smooth_local_refnode_velocity = lowpass_vec(M.smooth_local_refnode_velocity, raw_local_refnode_velocity, dt, LOCAL_SMOOTH_RATE)
      M.smooth_local_body_angular_velocity = lowpass_vec(M.smooth_local_body_angular_velocity, raw_local_body_angular_velocity, dt, LOCAL_SMOOTH_RATE)
      local_refnode_velocity = M.smooth_local_refnode_velocity
      local_body_angular_velocity = M.smooth_local_body_angular_velocity
    end
    local local_angular_velocity = local_body_angular_velocity:rotated(local_rot)
    -- Cluster convention: v_cog = v_refnode + cog_offset_world x omega_world.
    local local_cog_position = local_refnode_position + cog_offset_world
    local local_cog_velocity = local_refnode_velocity + cog_offset_world:cross(local_angular_velocity)

    -- Observed velocity-delta this frame, world frame at COG. Used by the
    -- overshoot dampener to detect when the body didn't deliver what we
    -- asked for last frame.
    local delivered_linear_step = (M.last_cog_velocity == nil) and vec3(0,0,0) or (local_cog_velocity - M.last_cog_velocity)
    local delivered_angular_step = (M.last_body_angular_velocity == nil) and vec3(0,0,0) or (local_angular_velocity - M.last_body_angular_velocity)
    M.last_cog_velocity = local_cog_velocity
    M.last_body_angular_velocity = local_angular_velocity

    -- Target state in world frame. Wire is COG-anchored.
    local target_rotation = target_cluster_rotation
    local target_angular_velocity = target_cluster_angular_velocity

    -- Errors.
    local cog_position_error = target_cog_position - local_cog_position
    local cog_velocity_error = target_cog_velocity - local_cog_velocity

    -- Rotation error: small-angle approximation via local-frame Euler of
    -- (current.inverse * target), swizzled to (eul.y, eul.z, eul.x) to
    -- match the gyro / ω packing convention used elsewhere on the wire.
    local rotation_error_quaternion = local_rot:inversed() * target_rotation
    local rotation_error_euler = rotation_error_quaternion:toEulerYXZ()
    local orientation_error = vec3(rotation_error_euler.y, rotation_error_euler.z, rotation_error_euler.x)
    local spin_error = target_angular_velocity - local_angular_velocity

    local linear_step, angular_step = ClusterServo:solve_step(
      cog_position_error, cog_velocity_error,
      orientation_error, spin_error,
      dt
    )

    -- Overshoot dampener. step_error is (what we asked for last frame) -
    -- (what the body actually delivered this frame). If our current
    -- requested correction direction agrees with the failure direction,
    -- the body is saturating and pushing harder will overshoot; scale
    -- the correction down. The (max_err^2 * dt) floor in the denominator
    -- means tiny errors don't trigger heavy damping.
    local last_linear_step = M.last_linear_step or delivered_linear_step
    local last_angular_step = M.last_angular_step or delivered_angular_step
    local raw_linear_step_error = last_linear_step - delivered_linear_step
    local raw_angular_step_error = last_angular_step - delivered_angular_step
    M.smooth_linear_step_error = lowpass_vec(M.smooth_linear_step_error, raw_linear_step_error, dt, ERROR_SMOOTH_RATE)
    M.smooth_angular_step_error = lowpass_vec(M.smooth_angular_step_error, raw_angular_step_error, dt, ERROR_SMOOTH_RATE)

    local linear_denom = linear_step:squaredLength() + (MAX_LINEAR_STEP_ERROR * MAX_LINEAR_STEP_ERROR) * dt
    local angular_denom = angular_step:squaredLength() + (MAX_ANGULAR_STEP_ERROR * MAX_ANGULAR_STEP_ERROR) * dt

    local linear_mul = 1.0 - math.min(math.max(linear_step:dot(M.smooth_linear_step_error) / linear_denom, 0), 1)
    local angular_mul = 1.0 - math.min(math.max(angular_step:dot(M.smooth_angular_step_error) / angular_denom, 0), 1)

    linear_step = linear_step * linear_mul
    angular_step = angular_step * angular_mul

    M.last_linear_step = linear_step
    M.last_angular_step = angular_step

    -- Bob diagnostic: rate-limited dump of error/step magnitudes so we can
    -- see whether static bobbing is driven by position error, velocity error,
    -- or stale step output.
    local now_log = current_time
    if M.debug and (M.last_bob_log_time or 0) + 0.25 < now_log then
      M.last_bob_log_time = now_log
      print(string.format(
        "[bob vid=%d] pos_err=%.3f vel_err=%.3f rot_err=%.3f spin_err=%.3f lin_step=%.4f ang_step=%.4f local_v=%.3f",
        obj:getID() or -1,
        cog_position_error:length(), cog_velocity_error:length(),
        orientation_error:length(), spin_error:length(),
        linear_step:length(), angular_step:length(),
        local_cog_velocity:length()
      ))
    end

    ClusterServo:apply_cluster_step(refnode_cid, cog_offset_world, linear_step, angular_step, local_cog_velocity:length())
  end

  if M.debug then
    draw_debug(synced_transform)
  end
end

M.rude_error_time = 0

-- Apply authoritative snapshot from wire. Runs once per received packet
-- (queued by kisstransform.update_vehicle_transform). Just caches; no
-- force application here. Force pulls happen every Lua frame from update(dt)
-- so the correction is sustained and doesn't depend on packet cadence.
local function set_target_transform(raw)
  local transform = jsonDecode(raw)

  if transform.owner then
    if M.sync_id ~= nil and M.sync_id ~= transform.owner then
      kiss_sync.reset_sync_state(transform.owner)
    end
    M.sync_id = transform.owner
  end
  if not M.sync_id then return end

  local current_time = get_local_sync_time()
  local snapshot_timestamp = transform.send_timer
  if not snapshot_timestamp or snapshot_timestamp <= 0 then
    snapshot_timestamp = transform.sent_at or current_time
  end
  local own_ping = ((transform.receiver_ping_ms or 0) * 0.001)
  local remote_ping = ((transform.ping_ms or 0) * 0.001)
  transform.time_offset = current_time - snapshot_timestamp - (own_ping * 0.5) - (remote_ping * 0.5) - (M.last_update_dt or 0)
  -- Prefer send_timer (sender-monotonic) over sent_at (sender wall-clock,
  -- subject to cross-machine skew) when both are present. The blend
  -- argument is left as 0; kiss_sync extrapolates forward and the PD
  -- loop on this side handles motion smoothness; an additional snapshot
  -- blend would only inject lag.
  kiss_sync.apply_snapshot(
    M.sync_id, transform,
    snapshot_timestamp,
    transform.generation or 0,
    current_time, 0
  )
end

local function snap_to_cog_target(target_cog_position_x, target_cog_position_y, target_cog_position_z, target_rotation_x, target_rotation_y, target_rotation_z, target_rotation_w, target_velocity_x, target_velocity_y, target_velocity_z, target_angular_velocity_x, target_angular_velocity_y, target_angular_velocity_z)
  if kiss_vehicle and kiss_vehicle.maybe_recompute_sync_cog_body then
    kiss_vehicle.maybe_recompute_sync_cog_body()
  end

  local target_rotation = quat(target_rotation_x, target_rotation_y, target_rotation_z, target_rotation_w)
  local target_cog_position = vec3(target_cog_position_x, target_cog_position_y, target_cog_position_z)
  local target_cog_velocity = vec3(target_velocity_x or 0, target_velocity_y or 0, target_velocity_z or 0)
  local target_angular_velocity = vec3(target_angular_velocity_x or 0, target_angular_velocity_y or 0, target_angular_velocity_z or 0)
  local target_cog_offset_world = target_rotation * get_cog_body()
  local target_origin = target_cog_position - target_cog_offset_world
  local target_origin_velocity = target_cog_velocity - target_cog_offset_world:cross(target_angular_velocity)

  clear_drift_state()
  if M.sync_id and kiss_sync and kiss_sync.reset_motion_smoothers then
    kiss_sync.reset_motion_smoothers(M.sync_id)
  end

  obj:queueGameEngineLua(
    "kisstransform.apply_cluster_target("..obj:getID()..","
    ..target_origin.x..","..target_origin.y..","..target_origin.z..","
    ..target_rotation.x..","..target_rotation.y..","..target_rotation.z..","..target_rotation.w..","
    ..target_origin_velocity.x..","..target_origin_velocity.y..","..target_origin_velocity.z..")"
  )
end

local function post_teleport_cooldown(duration)
  clear_drift_state()
  if M.sync_id and kiss_sync and kiss_sync.reset_sync_state then
    kiss_sync.reset_sync_state(M.sync_id)
  end
  M.rude_error_time = 0
  M.cooldown_timer = math.max(M.cooldown_timer or 0, duration or 0.35)
end

local function onExtensionLoaded()
  M.sync_id = obj:getID()
  if kiss_vehicle and kiss_vehicle.maybe_recompute_sync_cog_body then
    kiss_vehicle.maybe_recompute_sync_cog_body()
  end
  local current_rotation = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local current_pos = vec3(obj:getPosition()) + current_rotation * get_cog_body()

  -- Seed kiss_sync at the current COG so first update has no startup snap.
  local current_time = get_local_sync_time()
  local initial_transform = {
    position = {current_pos.x, current_pos.y, current_pos.z},
    rotation = {current_rotation.x, current_rotation.y, current_rotation.z, current_rotation.w},
    velocity = {0, 0, 0},
    angular_velocity = {0, 0, 0},
  }
  kiss_sync.apply_snapshot(M.sync_id, initial_transform, current_time, 0, current_time, 0)

  clear_drift_state()
  M.rude_error_time = 0
  M.cooldown_timer = 1.5
end

local function kissUpdateOwnership(owned)
  M.ownership = owned and true or false
  M.ownership_known = true
  if M.ownership then
    clear_drift_state()
  end
end

local function onReset()
  if M.sync_id then
    kiss_sync.reset_sync_state(M.sync_id)
  end
  clear_drift_state()
  M.rude_error_time = 0
  M.cooldown_timer = 0.2
  -- Do not carry observed delta-v across a reset.
  M.last_linear_step = nil
  M.last_angular_step = nil
  M.last_cog_velocity = nil
  M.last_body_angular_velocity = nil
end

M.set_target_transform = set_target_transform
M.snap_to_cog_target = snap_to_cog_target
M.post_teleport_cooldown = post_teleport_cooldown
M.set_linear_pull_scale = set_linear_pull_scale
M.set_angular_pull_scale = set_angular_pull_scale
M.update = update
M.updateGFX = update
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.kissUpdateOwnership = kissUpdateOwnership
M.get_synced_transform = get_synced_transform

return M
