-- KissMP Sync Module: second-order dead-reckoning prediction.
--
-- Maintains per-vehicle sync state on the receiver. Each packet carries
-- position/velocity/rotation/angular-velocity (no acceleration); we derive
-- acceleration from velocity deltas across consecutive packets and use it
-- in a constant-acceleration extrapolation model so the consumer (the PD
-- loop in kiss_transforms.update) chases where the sender IS NOW, not where
-- the sender WAS when the packet was sent.
--
-- The blend path is dormant in normal use because apply_snapshot is called
-- with blend_duration = 0. It remains available for explicit experiments.

local M = {}

local function vec3_add(a, b)
  return vec3(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_scale(v, s)
  return vec3(v.x * s, v.y * s, v.z * s)
end

local function vec3_lerp(a, b, t)
  return vec3(
    a.x + (b.x - a.x) * t,
    a.y + (b.y - a.y) * t,
    a.z + (b.z - a.z) * t
  )
end

local function vec3_copy(v)
  return vec3(v.x, v.y, v.z)
end

-- Quaternion multiplication: q_result = q1 * q2.
local function quat_multiply(q1, q2)
  return quat(
    q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
    q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
    q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w,
    q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z
  )
end

-- Extrapolate quaternion using world-frame angular velocity.
-- q(t + dt) = exp(omega_world * dt / 2) * q(t)
local function extrapolate_quaternion(q, omega, delta_time)
  local omega_magnitude = omega:length()
  if omega_magnitude < 1e-8 or delta_time < 1e-8 then return q end

  local theta = omega_magnitude * delta_time
  local half_theta = theta * 0.5
  local sin_half_theta = math.sin(half_theta)
  local cos_half_theta = math.cos(half_theta)

  local axis_scale = sin_half_theta / omega_magnitude
  local delta_q = quat(
    omega.x * axis_scale,
    omega.y * axis_scale,
    omega.z * axis_scale,
    cos_half_theta
  )
  return quat_multiply(delta_q, q)
end

local function slerp_quaternion(q1, q2, t)
  local dot = q1.w * q2.w + q1.x * q2.x + q1.y * q2.y + q1.z * q2.z
  local q2_interp = q2
  if dot < 0.0 then
    dot = -dot
    q2_interp = quat(-q2.x, -q2.y, -q2.z, -q2.w)
  end
  dot = math.max(-1.0, math.min(1.0, dot))

  if dot > 0.9995 then
    local result = quat(
      q1.x + (q2_interp.x - q1.x) * t,
      q1.y + (q2_interp.y - q1.y) * t,
      q1.z + (q2_interp.z - q1.z) * t,
      q1.w + (q2_interp.w - q1.w) * t
    )
    return result:normalized()
  end

  local theta = math.acos(dot)
  local sin_theta = math.sin(theta)

  if sin_theta < 1e-8 then
    local result = quat(
      q1.x + (q2_interp.x - q1.x) * t,
      q1.y + (q2_interp.y - q1.y) * t,
      q1.z + (q2_interp.z - q1.z) * t,
      q1.w + (q2_interp.w - q1.w) * t
    )
    return result:normalized()
  end

  local ratio_a = math.sin((1.0 - t) * theta) / sin_theta
  local ratio_b = math.sin(t * theta) / sin_theta

  local result = quat(
    q1.x * ratio_a + q2_interp.x * ratio_b,
    q1.y * ratio_a + q2_interp.y * ratio_b,
    q1.z * ratio_a + q2_interp.z * ratio_b,
    q1.w * ratio_a + q2_interp.w * ratio_b
  )
  return result:normalized()
end

local MAX_LINEAR_ACCEL     = 100   -- m/s^2 clamp on derived linear acceleration
local MAX_ANGULAR_ACCEL    = 50    -- rad/s^2 clamp on derived angular acceleration
local MAX_PREDICT = 0.3   -- seconds; clamp on forward-extrapolation horizon
local PACKET_TIMEOUT = 0.1 -- Stop correcting if packets stall
local STALE_THRESHOLD = 2.0
local USE_PREDICTION = true
M.REMOTE_VEL_SMOOTH_RATE = 2.0
M.PREDICTION_OFFSET_S = 0.0
local REMOTE_ACCEL_SMOOTH_RATE = 1.0
local TIME_OFFSET_SMOOTH_RATE = 1.0

local function set_smoothing_tuning(vel_rate, prediction_offset_s)
  if type(vel_rate) == "number" then
    M.REMOTE_VEL_SMOOTH_RATE = math.max(0, vel_rate)
  end
  if type(prediction_offset_s) == "number" then
    M.PREDICTION_OFFSET_S = math.max(-0.08, math.min(prediction_offset_s, 0.08))
  end
end

local function limit_vec(v, max_len)
  local len = v:length()
  if len > max_len then return v * (max_len / len) end
  return v
end

local function smoothing_dt(frame_dt, predict_time)
  return frame_dt / math.max(math.abs(predict_time), 0.001)
end

local function create_sync_state(id)
  return {
    id = id,
    -- Last authoritative snapshot from wire.
    base_transform = {
      position = vec3(0, 0, 0),
      rotation = quat(0, 0, 0, 1),
      velocity = vec3(0, 0, 0),
      angular_velocity = vec3(0, 0, 0),
    },
    -- Derived from velocity deltas in apply_snapshot and used by the
    -- second-order extrapolator.
    linear_accel  = vec3(0, 0, 0),
    angular_accel = vec3(0, 0, 0),
    smooth_velocity = nil,
    smooth_angular_velocity = nil,
    smooth_linear_accel = nil,
    smooth_angular_accel = nil,
    last_raw_velocity = nil,
    last_raw_angular_velocity = nil,
    last_smooth_time = 0,

    base_timestamp = 0,        -- sender's monotonic timer in seconds
    base_recv_time = 0,        -- local clock at packet arrival
    generation = 0,
    last_update_time = 0,

    time_offset_target = 0,
    time_offset_smoothed = nil,

    -- Prediction state (populated by update_and_get_transform).
    predicted_transform = {
      position = vec3(0, 0, 0),
      rotation = quat(0, 0, 0, 1),
      velocity = vec3(0, 0, 0),
      angular_velocity = vec3(0, 0, 0),
    },
    -- Blend infrastructure; dormant by default.
    blend_start = nil,
    blend_target = nil,
    blend_start_time = 0,
    blend_duration = 0,
    is_blending = false,

    -- Applied transform (what update_and_get_transform returns).
    applied_transform = {
      position = vec3(0, 0, 0),
      rotation = quat(0, 0, 0, 1),
      velocity = vec3(0, 0, 0),
      angular_velocity = vec3(0, 0, 0),
    },
  }
end

-- Forward-extrapolate the latest authoritative snapshot to the current local
-- time. The acceleration term keeps transients from lagging by 0.5*a*t^2.
local function extrapolate_transform(state, current_time)
  local frame_dt = 0
  if state.last_smooth_time and state.last_smooth_time > 0 then
    frame_dt = math.max(0, current_time - state.last_smooth_time)
  end
  state.last_smooth_time = current_time

  if state.time_offset_smoothed == nil then
    state.time_offset_smoothed = state.time_offset_target or 0
  elseif frame_dt > 0 then
    state.time_offset_smoothed = state.time_offset_smoothed
      + ((state.time_offset_target or state.time_offset_smoothed) - state.time_offset_smoothed)
      * math.min(TIME_OFFSET_SMOOTH_RATE * frame_dt, 1.0)
  end

  local calc_local_time = state.base_timestamp + (state.time_offset_smoothed or 0)
  local predict_time = math.max(
    -MAX_PREDICT,
    math.min((current_time - calc_local_time) + M.PREDICTION_OFFSET_S, MAX_PREDICT)
  )
  local t = predict_time

  if frame_dt > 0 then
    local smooth_dt = smoothing_dt(frame_dt, predict_time)
    state.smooth_velocity = vec3_lerp(
      state.smooth_velocity or state.base_transform.velocity,
      state.base_transform.velocity,
      math.min(M.REMOTE_VEL_SMOOTH_RATE * smooth_dt, 1.0)
    )
    state.smooth_angular_velocity = vec3_lerp(
      state.smooth_angular_velocity or state.base_transform.angular_velocity,
      state.base_transform.angular_velocity,
      math.min(M.REMOTE_VEL_SMOOTH_RATE * smooth_dt, 1.0)
    )
    state.smooth_linear_accel = vec3_lerp(
      state.smooth_linear_accel or state.linear_accel,
      state.linear_accel,
      math.min(REMOTE_ACCEL_SMOOTH_RATE * smooth_dt, 1.0)
    )
    state.smooth_angular_accel = vec3_lerp(
      state.smooth_angular_accel or state.angular_accel,
      state.angular_accel,
      math.min(REMOTE_ACCEL_SMOOTH_RATE * smooth_dt, 1.0)
    )
  end

  local base = state.base_transform
  local base_velocity = state.smooth_velocity or base.velocity
  local base_angular_velocity = state.smooth_angular_velocity or base.angular_velocity
  local linear_accel = state.smooth_linear_accel or state.linear_accel or vec3(0, 0, 0)
  local angular_accel = state.smooth_angular_accel or state.angular_accel or vec3(0, 0, 0)
  local half_t_sq = 0.5 * t * t

  -- Position: x(t) = x0 + v0*t + 0.5*a*t^2
  local pred_pos = vec3(
    base.position.x + base_velocity.x * t + linear_accel.x * half_t_sq,
    base.position.y + base_velocity.y * t + linear_accel.y * half_t_sq,
    base.position.z + base_velocity.z * t + linear_accel.z * half_t_sq
  )

  -- Velocity: v(t) = v0 + a*t
  local pred_vel = vec3(
    base_velocity.x + linear_accel.x * t,
    base_velocity.y + linear_accel.y * t,
    base_velocity.z + linear_accel.z * t
  )

  -- Rotation delta as a small-angle vector then converted to a delta
  -- quaternion. rot_add = omega0*t + 0.5*alpha*t^2 in world frame.
  local rot_add = vec3(
    base_angular_velocity.x * t + angular_accel.x * half_t_sq,
    base_angular_velocity.y * t + angular_accel.y * half_t_sq,
    base_angular_velocity.z * t + angular_accel.z * half_t_sq
  )
  local pred_rot = base.rotation * quatFromEuler(rot_add.x, rot_add.y, rot_add.z)

  -- Angular velocity: omega(t) = omega0 + alpha*t
  local pred_omega = vec3(
    base_angular_velocity.x + angular_accel.x * t,
    base_angular_velocity.y + angular_accel.y * t,
    base_angular_velocity.z + angular_accel.z * t
  )

  return {
    position         = pred_pos,
    rotation         = pred_rot,
    velocity         = pred_vel,
    angular_velocity = pred_omega,
  }
end

-- Blend between two transforms.
local function blend_transforms(start, target, t)
  local position = vec3_lerp(start.position, target.position, t)
  local rotation = slerp_quaternion(start.rotation, target.rotation, t)
  local velocity = vec3(
    start.velocity.x + (target.velocity.x - start.velocity.x) * t,
    start.velocity.y + (target.velocity.y - start.velocity.y) * t,
    start.velocity.z + (target.velocity.z - start.velocity.z) * t
  )
  local angular_velocity = vec3(
    start.angular_velocity.x + (target.angular_velocity.x - start.angular_velocity.x) * t,
    start.angular_velocity.y + (target.angular_velocity.y - start.angular_velocity.y) * t,
    start.angular_velocity.z + (target.angular_velocity.z - start.angular_velocity.z) * t
  )
  return {
    position = position,
    rotation = rotation,
    velocity = velocity,
    angular_velocity = angular_velocity,
  }
end

M.sync_states = {}
M.default_blend_duration = 0

local function get_sync_state(id)
  if not M.sync_states[id] then
    M.sync_states[id] = create_sync_state(id)
  end
  return M.sync_states[id]
end

local function apply_snapshot(id, transform_data, timestamp, generation, current_time, blend_duration)
  blend_duration = blend_duration or M.default_blend_duration

  local state = get_sync_state(id)
  local is_first_snapshot = (state.base_timestamp == 0)
  local timestamp_delta = timestamp - state.base_timestamp

  -- Stale fallback: if no updates arrived for >STALE_THRESHOLD seconds,
  -- treat the next packet as a fresh start. Don't derive acceleration
  -- from a velocity gap that spans seconds; the divisor would be huge,
  -- the result tiny, and we'd carry stale state forward. The primary
  -- teleport recovery path is a separate ResetVehicle packet sent by the
  -- owner; this just covers gaps if that's lost.
  local is_stale = false
  if state.last_update_time > 0 then
    if (current_time - state.last_update_time) > STALE_THRESHOLD then
      is_stale = true
    end
  end

  -- Handle remote timer resets and ignore old packets.
  -- Without this, a reset to a low sender timer or a slightly out-of-order
  -- packet produces a near-zero remote_dt below and turns a normal velocity
  -- delta into a bogus 100 m/s^2 acceleration spike.
  if not is_first_snapshot and timestamp_delta <= 0 then
    if timestamp_delta == 0 or math.abs(timestamp_delta) < 0.5 then
      return
    end
    is_stale = true
  end

  -- Parse incoming transform data into vec3/quat objects.
  local authoritative = {
    position         = vec3(transform_data.position[1], transform_data.position[2], transform_data.position[3]),
    rotation         = quat(transform_data.rotation[1], transform_data.rotation[2], transform_data.rotation[3], transform_data.rotation[4]),
    velocity         = vec3(transform_data.velocity[1], transform_data.velocity[2], transform_data.velocity[3]),
    angular_velocity = vec3(transform_data.angular_velocity[1], transform_data.angular_velocity[2], transform_data.angular_velocity[3]),
  }

  -- Derive acceleration from packet velocity deltas. Velocity itself is
  -- smoothed because authoritative.velocity carries the receiver's only
  -- noise floor.
  local remote_dt = math.max(timestamp_delta, 0.001)
  local raw_linear_accel = vec3(0, 0, 0)
  local raw_angular_accel = vec3(0, 0, 0)
  if is_first_snapshot or is_stale then
    state.smooth_velocity = vec3_copy(authoritative.velocity)
    state.smooth_angular_velocity = vec3_copy(authoritative.angular_velocity)
    state.smooth_linear_accel = vec3(0, 0, 0)
    state.smooth_angular_accel = vec3(0, 0, 0)
  else
    local prev_raw_vel = state.last_raw_velocity or state.base_transform.velocity
    raw_linear_accel = limit_vec(vec3(
      (authoritative.velocity.x - prev_raw_vel.x) / remote_dt,
      (authoritative.velocity.y - prev_raw_vel.y) / remote_dt,
      (authoritative.velocity.z - prev_raw_vel.z) / remote_dt
    ), MAX_LINEAR_ACCEL)

    local prev_raw_rvel = state.last_raw_angular_velocity or state.base_transform.angular_velocity
    raw_angular_accel = limit_vec(vec3(
      (authoritative.angular_velocity.x - prev_raw_rvel.x) / remote_dt,
      (authoritative.angular_velocity.y - prev_raw_rvel.y) / remote_dt,
      (authoritative.angular_velocity.z - prev_raw_rvel.z) / remote_dt
    ), MAX_ANGULAR_ACCEL)

  end
  state.last_raw_velocity = vec3_copy(authoritative.velocity)
  state.last_raw_angular_velocity = vec3_copy(authoritative.angular_velocity)
  state.linear_accel  = raw_linear_accel
  state.angular_accel = raw_angular_accel

  -- Update base + receive timing.
  state.base_transform = {
    position         = authoritative.position,
    rotation         = authoritative.rotation,
    velocity         = authoritative.velocity,
    angular_velocity = authoritative.angular_velocity,
  }
  state.base_timestamp  = timestamp
  state.base_recv_time  = current_time
  state.time_offset_target = transform_data.time_offset or (current_time - timestamp)
  if is_first_snapshot or is_stale or state.time_offset_smoothed == nil then
    state.time_offset_smoothed = state.time_offset_target
  end
  state.generation      = generation
  state.last_update_time = current_time
  if state.last_smooth_time <= 0 then
    state.last_smooth_time = current_time
  end

  -- Optional blend path (dormant by default). When blend_duration > 0
  -- and not first/stale, set up a blend from the previously-applied pose
  -- to the new authoritative pose. Otherwise snap applied_transform;
  -- update_and_get_transform will overwrite it next frame anyway via
  -- the predictor, but snapping here keeps it consistent if no consumer
  -- runs before the next snapshot.
  if is_first_snapshot or is_stale or blend_duration <= 0 then
    state.applied_transform = {
      position         = authoritative.position,
      rotation         = authoritative.rotation,
      velocity         = state.base_transform.velocity,
      angular_velocity = state.base_transform.angular_velocity,
    }
    state.is_blending = false
  else
    state.blend_start = {
      position         = state.applied_transform.position,
      rotation         = state.applied_transform.rotation,
      velocity         = state.applied_transform.velocity,
      angular_velocity = state.applied_transform.angular_velocity,
    }
    state.blend_target = authoritative
    state.blend_target.velocity = state.base_transform.velocity
    state.blend_target.angular_velocity = state.base_transform.angular_velocity
    state.blend_start_time = current_time
    state.blend_duration = blend_duration
    state.is_blending = true
  end
end

local function update_and_get_transform(id, current_time)
  local state = get_sync_state(id)
  if state.base_timestamp == 0 then
    return state.applied_transform
  end
  if (current_time - state.base_recv_time) > PACKET_TIMEOUT then
    return nil
  end

  -- Always extrapolate forward to current_time.
  state.predicted_transform = extrapolate_transform(state, current_time)

  -- Blend path stays callable but dormant when blend_duration = 0
  -- (the default flow). When active, blend interpolates between
  -- blend_start and blend_target; we use it as the applied transform
  -- in that branch so the consumer sees a smoothed transition.
  if state.is_blending then
    local elapsed = current_time - state.blend_start_time
    local t = math.max(0, math.min(1, elapsed / state.blend_duration))
    local blended = blend_transforms(state.blend_start, state.blend_target, t)
    state.applied_transform = {
      position         = blended.position,
      rotation         = blended.rotation,
      velocity         = blended.velocity,
      angular_velocity = blended.angular_velocity,
    }
    if t >= 1.0 then
      state.is_blending = false
    end
  else
    state.applied_transform = {
      position         = state.predicted_transform.position,
      rotation         = state.predicted_transform.rotation,
      velocity         = state.predicted_transform.velocity,
      angular_velocity = state.predicted_transform.angular_velocity,
    }
  end

  return state.applied_transform
end

local function set_blend_duration(duration)
  M.default_blend_duration = math.max(0, duration)
end

local function get_blend_progress(id, current_time)
  local state = get_sync_state(id)
  if not state.is_blending then
    return 1.0
  end
  local elapsed = current_time - state.blend_start_time
  return math.max(0, math.min(1, elapsed / state.blend_duration))
end

local function is_initialized(id)
  local state = M.sync_states[id]
  return state ~= nil and state.base_timestamp > 0
end

local function reset_sync_state(id)
  M.sync_states[id] = create_sync_state(id)
end

local function reset_motion_smoothers(id)
  local state = M.sync_states[id]
  if not state then return end
  local base = state.base_transform
  state.linear_accel = vec3(0, 0, 0)
  state.angular_accel = vec3(0, 0, 0)
  state.smooth_velocity = vec3_copy(base.velocity)
  state.smooth_angular_velocity = vec3_copy(base.angular_velocity)
  state.smooth_linear_accel = vec3(0, 0, 0)
  state.smooth_angular_accel = vec3(0, 0, 0)
  state.last_raw_velocity = vec3_copy(base.velocity)
  state.last_raw_angular_velocity = vec3_copy(base.angular_velocity)
  state.last_smooth_time = 0
  state.is_blending = false
end

-- Cleanup stale sync states from despawned vehicles.
local function cleanup_stale_states(max_age)
  max_age = max_age or 30.0
  local current_time = be:getTime() or 0
  local cleaned = 0
  for id, state in pairs(M.sync_states) do
    if state.last_update_time > 0 then
      local age = current_time - state.last_update_time
      if age > max_age then
        M.sync_states[id] = nil
        cleaned = cleaned + 1
      end
    end
  end
  return cleaned
end

local function refresh_all_states()
  local count = 0
  for _ in pairs(M.sync_states) do
    count = count + 1
  end
  M.sync_states = {}
  return count
end

M.set_smoothing_tuning = set_smoothing_tuning
M.apply_snapshot = apply_snapshot
M.update_and_get_transform = update_and_get_transform
M.get_sync_state = get_sync_state
M.set_blend_duration = set_blend_duration
M.get_blend_progress = get_blend_progress
M.is_initialized = is_initialized
M.reset_sync_state = reset_sync_state
M.reset_motion_smoothers = reset_motion_smoothers
M.slerp_quaternion = slerp_quaternion
M.cleanup_stale_states = cleanup_stale_states
M.refresh_all_states = refresh_all_states

return M
