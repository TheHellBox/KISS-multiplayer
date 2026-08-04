-- KissMP Sync Module: second-order dead-reckoning prediction.
--
-- Maintains per-vehicle sync state on the receiver. Each packet carries
-- position/velocity/rotation/angular-velocity (no acceleration); we derive
-- acceleration from velocity deltas across consecutive packets and use it
-- in a constant-acceleration extrapolation model so the consumer (the PD
-- loop in kiss_motion_controller.update) chases where the sender IS NOW, not where
-- the sender WAS when the packet was sent.
--
local M = {}

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

local MAX_LINEAR_ACCELERATION     = 100   -- m/s^2 clamp on derived linear acceleration
local MAX_PREDICT = 0.3   -- seconds; clamp on forward-extrapolation horizon
local PACKET_TIMEOUT = 0.1 -- Stop correcting if packets stall
local STALE_THRESHOLD = 2.0
M.REMOTE_VEL_SMOOTH_RATE = 2.0
M.PREDICTION_OFFSET_S = 0.0
local REMOTE_ACCELERATION_SMOOTH_RATE = 1.0
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
    linear_acceleration  = vec3(0, 0, 0),
    smooth_velocity = nil,
    smooth_angular_velocity = nil,
    smooth_linear_acceleration = nil,
    last_raw_velocity = nil,
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
    state.smooth_linear_acceleration = vec3_lerp(
      state.smooth_linear_acceleration or state.linear_acceleration,
      state.linear_acceleration,
      math.min(REMOTE_ACCELERATION_SMOOTH_RATE * smooth_dt, 1.0)
    )
  end

  local base = state.base_transform
  local base_velocity = state.smooth_velocity or base.velocity
  local base_angular_velocity = state.smooth_angular_velocity or base.angular_velocity
  local linear_acceleration = state.smooth_linear_acceleration or state.linear_acceleration or vec3(0, 0, 0)
  -- Do not second-order predict angular motion. Angular acceleration is
  -- derived from lossy packet-to-packet angular velocity deltas, and fake
  -- yaw accel impulses are much more visible than small heading lag.
  local half_t_sq = 0.5 * t * t

  -- Position: x(t) = x0 + v0*t + 0.5*a*t^2
  local predicted_position = vec3(
    base.position.x + base_velocity.x * t + linear_acceleration.x * half_t_sq,
    base.position.y + base_velocity.y * t + linear_acceleration.y * half_t_sq,
    base.position.z + base_velocity.z * t + linear_acceleration.z * half_t_sq
  )

  -- Velocity: v(t) = v0 + a*t
  local predicted_velocity = vec3(
    base_velocity.x + linear_acceleration.x * t,
    base_velocity.y + linear_acceleration.y * t,
    base_velocity.z + linear_acceleration.z * t
  )

  -- Rotation: first-order angular prediction only. Linear motion still uses
  -- acceleration prediction to preserve path tracking.
  local rotation_delta = vec3(
    base_angular_velocity.x * t,
    base_angular_velocity.y * t,
    base_angular_velocity.z * t
  )
  local predicted_rotation = base.rotation * quatFromEuler(rotation_delta.x, rotation_delta.y, rotation_delta.z)

  local predicted_angular_velocity = base_angular_velocity

  return {
    position         = predicted_position,
    rotation         = predicted_rotation,
    velocity         = predicted_velocity,
    angular_velocity = predicted_angular_velocity,
  }
end

M.sync_states = {}

local function get_sync_state(id)
  if not M.sync_states[id] then
    M.sync_states[id] = create_sync_state(id)
  end
  return M.sync_states[id]
end

local function apply_snapshot(id, transform_data, timestamp, generation, current_time)
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
  local raw_linear_acceleration = vec3(0, 0, 0)
  if is_first_snapshot or is_stale then
    state.smooth_velocity = vec3_copy(authoritative.velocity)
    state.smooth_angular_velocity = vec3_copy(authoritative.angular_velocity)
    state.smooth_linear_acceleration = vec3(0, 0, 0)
  else
    local previous_raw_velocity = state.last_raw_velocity or state.base_transform.velocity
    raw_linear_acceleration = limit_vec(vec3(
      (authoritative.velocity.x - previous_raw_velocity.x) / remote_dt,
      (authoritative.velocity.y - previous_raw_velocity.y) / remote_dt,
      (authoritative.velocity.z - previous_raw_velocity.z) / remote_dt
    ), MAX_LINEAR_ACCELERATION)

  end
  state.last_raw_velocity = vec3_copy(authoritative.velocity)
  state.linear_acceleration  = raw_linear_acceleration

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

  state.applied_transform = {
    position         = authoritative.position,
    rotation         = authoritative.rotation,
    velocity         = state.base_transform.velocity,
    angular_velocity = state.base_transform.angular_velocity,
  }
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

  state.applied_transform = {
    position         = state.predicted_transform.position,
    rotation         = state.predicted_transform.rotation,
    velocity         = state.predicted_transform.velocity,
    angular_velocity = state.predicted_transform.angular_velocity,
  }

  return state.applied_transform
end

local function reset_sync_state(id)
  M.sync_states[id] = create_sync_state(id)
end

local function reset_motion_smoothers(id)
  local state = M.sync_states[id]
  if not state then return end
  local base = state.base_transform
  state.linear_acceleration = vec3(0, 0, 0)
  state.smooth_velocity = vec3_copy(base.velocity)
  state.smooth_angular_velocity = vec3_copy(base.angular_velocity)
  state.smooth_linear_acceleration = vec3(0, 0, 0)
  state.last_raw_velocity = vec3_copy(base.velocity)
  state.last_smooth_time = 0
end

M.set_smoothing_tuning = set_smoothing_tuning
M.apply_snapshot = apply_snapshot
M.update_and_get_transform = update_and_get_transform
M.get_sync_state = get_sync_state
M.reset_sync_state = reset_sync_state
M.reset_motion_smoothers = reset_motion_smoothers
M.slerp_quaternion = slerp_quaternion

return M
