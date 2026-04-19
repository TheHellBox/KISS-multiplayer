-- KissMP Sync Module - Dead-reckoning prediction and blending for state replay
-- Phase 1b: Core single-vehicle sync
--
-- This module implements direct state replay with prediction and blending,
-- replacing the old force-based interpolation approach.

local M = {}

--- Vector/quaternion helper functions
local function vec3_add(a, b)
  return vec3(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vec3_scale(v, s)
  return vec3(v.x * s, v.y * s, v.y * s, v.z * s)
end

local function vec3_lerp(a, b, t)
  return vec3(
    a.x + (b.x - a.x) * t,
    a.y + (b.y - a.y) * t,
    a.z + (b.z - a.z) * t
  )
end

--- Quaternion multiplication: q_result = q1 ⊗ q2
local function quat_multiply(q1, q2)
  return quat(
    q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z,
    q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
    q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
    q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w
  )
end

--- Extrapolate quaternion using angular velocity
--- q(t+Δt) = exp(ω_world·Δt/2) ⊗ q(t)
--- Uses world-frame angular velocity (from BeamNG physics)
local function extrapolate_quaternion(q, omega, delta_time)
  local omega_magnitude = omega:length()

  -- Handle zero angular velocity or zero delta time
  if omega_magnitude < 1e-8 or delta_time < 1e-8 then
    return q
  end

  -- Compute rotation angle: θ = |ω|·Δt
  local theta = omega_magnitude * delta_time
  local half_theta = theta * 0.5

  -- Compute delta quaternion from axis-angle
  local sin_half_theta = math.sin(half_theta)
  local cos_half_theta = math.cos(half_theta)

  local axis_scale = sin_half_theta / omega_magnitude
  local delta_q = quat(
    cos_half_theta,
    omega.x * axis_scale,
    omega.y * axis_scale,
    omega.z * axis_scale
  )

  return quat_multiply(delta_q, q)  -- World-frame: delta ⊗ q
end

--- Spherical linear interpolation between quaternions
local function slerp_quaternion(q1, q2, t)
  -- Compute dot product
  local dot = q1.w * q2.w + q1.x * q2.x + q1.y * q2.y + q1.z * q2.z

  -- If dot < 0, negate q2 to take shortest path
  local q2_interp = q2
  if dot < 0.0 then
    dot = -dot
    q2_interp = quat(-q2.w, -q2.x, -q2.y, -q2.z)
  end

  -- Clamp dot to [-1, 1] to handle floating point errors
  dot = math.max(-1.0, math.min(1.0, dot))

  -- If quaternions are nearly identical, use linear interpolation
  if dot > 0.9995 then
    local result = quat(
      q1.w + (q2_interp.w - q1.w) * t,
      q1.x + (q2_interp.x - q1.x) * t,
      q1.y + (q2_interp.y - q1.y) * t,
      q1.z + (q2_interp.z - q1.z) * t
    )
    return result:normalized()
  end

  -- Compute angle and sine
  local theta = math.acos(dot)
  local sin_theta = math.sin(theta)

  if sin_theta < 1e-8 then
    local result = quat(
      q1.w + (q2_interp.w - q1.w) * t,
      q1.x + (q2_interp.x - q1.x) * t,
      q1.y + (q2_interp.y - q1.y) * t,
      q1.z + (q2_interp.z - q1.z) * t
    )
    return result:normalized()
  end

  local ratio_a = math.sin((1.0 - t) * theta) / sin_theta
  local ratio_b = math.sin(t * theta) / sin_theta

  local result = quat(
    q1.w * ratio_a + q2_interp.w * ratio_b,
    q1.x * ratio_a + q2_interp.x * ratio_b,
    q1.y * ratio_a + q2_interp.y * ratio_b,
    q1.z * ratio_a + q2_interp.z * ratio_b
  )
  return result:normalized()
end

--- Sync state for a single vehicle/body
local function create_sync_state(id)
  return {
    id = id,
    -- Last authoritative snapshot from wire
    base_transform = {
      position = vec3(0, 0, 0),
      rotation = quat(0, 0, 0, 1),
      velocity = vec3(0, 0, 0),
      angular_velocity = vec3(0, 0, 0),
    },
    base_timestamp = 0,
    generation = 0,
    last_update_time = 0,  -- Track last update for stale detection
    -- Prediction state
    predicted_transform = {
      position = vec3(0, 0, 0),
      rotation = quat(0, 0, 0, 1),
      velocity = vec3(0, 0, 0),
      angular_velocity = vec3(0, 0, 0),
    },
    -- Blending state
    blend_start = nil,
    blend_target = nil,
    blend_start_time = 0,
    blend_duration = 0,
    is_blending = false,
    -- Applied transform (what's actually rendered)
    applied_transform = {
      position = vec3(0, 0, 0),
      rotation = quat(0, 0, 0, 1),
    },
  }
end

--- Extrapolate transform using dead-reckoning
local function extrapolate_transform(base, base_timestamp, target_timestamp)
  local delta_time = math.max(0, target_timestamp - base_timestamp)

  -- Extrapolate position: x(t+Δt) = x(t) + v(t)·Δt
  local new_position = vec3(
    base.position.x + base.velocity.x * delta_time,
    base.position.y + base.velocity.y * delta_time,
    base.position.z + base.velocity.z * delta_time
  )

  -- Extrapolate rotation using angular velocity
  local new_rotation = extrapolate_quaternion(
    base.rotation,
    base.angular_velocity,
    delta_time
  )

  return {
    position = new_position,
    rotation = new_rotation,
    velocity = base.velocity,
    angular_velocity = base.angular_velocity,
  }
end

--- Blend between two transforms
local function blend_transforms(start, target, t)
  -- Linear interpolation for position
  local position = vec3_lerp(start.position, target.position, t)

  -- Spherical linear interpolation for rotation
  local rotation = slerp_quaternion(start.rotation, target.rotation, t)

  -- Linear interpolation for velocities (for smooth transition)
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

--- Sync state manager for all vehicles
M.sync_states = {}
M.default_blend_duration = 0.15  -- 150ms default blend
local STALE_THRESHOLD = 2.0  -- Seconds before sync state is considered stale (fallback for teleport)
local USE_PREDICTION = false  -- Set to true to enable dead-reckoning prediction, false for direct state replay only (no drift)

--- Get or create sync state for a vehicle
local function get_sync_state(id)
  if not M.sync_states[id] then
    M.sync_states[id] = create_sync_state(id)
  end
  return M.sync_states[id]
end

--- Apply authoritative snapshot from wire
--- This is the main entry point when a VehicleUpdate arrives
local function apply_snapshot(id, transform_data, timestamp, generation, current_time, blend_duration)
  blend_duration = blend_duration or M.default_blend_duration

  local state = get_sync_state(id)
  local is_first_snapshot = (state.base_timestamp == 0)

  -- Fallback for missed teleports: if no updates arrived for >STALE_THRESHOLD seconds,
  -- snap instead of blending. The primary teleport path is a separate ResetVehicle
  -- packet sent by the owner after a debounce; this just covers gaps if that's lost.
  local is_stale = false
  if state.last_update_time > 0 then
    local time_since_last_update = current_time - state.last_update_time
    if time_since_last_update > STALE_THRESHOLD then
      is_stale = true
    end
  end

  -- Parse incoming transform data
  local authoritative = {
    position = vec3(transform_data.position[1], transform_data.position[2], transform_data.position[3]),
    rotation = quat(transform_data.rotation[1], transform_data.rotation[2], transform_data.rotation[3], transform_data.rotation[4]),
    velocity = vec3(transform_data.velocity[1], transform_data.velocity[2], transform_data.velocity[3]),
    angular_velocity = vec3(transform_data.angular_velocity[1], transform_data.angular_velocity[2], transform_data.angular_velocity[3]),
  }

  -- Compute predicted state based on last snapshot (for blending from where we thought we were)
  -- Skip extrapolation for stale state, first snapshot, or if prediction is disabled
  local predicted
  if is_stale or is_first_snapshot or not USE_PREDICTION then
    predicted = authoritative
  elseif state.base_timestamp > 0 then
    predicted = extrapolate_transform(state.base_transform, state.base_timestamp, timestamp)
  else
    predicted = authoritative
  end

  -- Update base transform to new authoritative snapshot
  state.base_transform = {
    position = authoritative.position,
    rotation = authoritative.rotation,
    velocity = authoritative.velocity,
    angular_velocity = authoritative.angular_velocity,
  }
  state.base_timestamp = timestamp
  state.generation = generation

  -- Handle blend: skip blending for stale state / first snapshot to avoid interpolating from stale data
  if is_first_snapshot or is_stale or blend_duration <= 0 then
    -- Instant snap for first snapshot, stale state, or when blend is disabled
    state.applied_transform = {
      position = authoritative.position,
      rotation = authoritative.rotation,
    }
    state.is_blending = false
  else
    -- Normal blend from predicted to authoritative
    state.blend_start = predicted
    state.blend_target = authoritative
    state.blend_start_time = current_time
    state.blend_duration = blend_duration
    state.is_blending = true

    -- Get initial blended state
    state.applied_transform = {
      position = predicted.position,
      rotation = predicted.rotation,
    }
  end

  -- Update last update time (after blend handling)
  state.last_update_time = current_time
end

--- Update sync state and get applied transform
--- Call this every frame to get the current transform
local function update_and_get_transform(id, current_time)
  local state = get_sync_state(id)

  -- Extrapolate prediction forward (only if prediction is enabled)
  if USE_PREDICTION then
    state.predicted_transform = extrapolate_transform(
      state.base_transform,
      state.base_timestamp,
      current_time
    )
  else
    -- No prediction: use base transform directly
    state.predicted_transform = {
      position = state.base_transform.position,
      rotation = state.base_transform.rotation,
      velocity = state.base_transform.velocity,
      angular_velocity = state.base_transform.angular_velocity,
    }
  end

  -- Update blend if active
  if state.is_blending then
    local elapsed = current_time - state.blend_start_time
    local t = math.max(0, math.min(1, elapsed / state.blend_duration))

    local blended = blend_transforms(state.blend_start, state.blend_target, t)

    state.applied_transform = {
      position = blended.position,
      rotation = blended.rotation,
      velocity = blended.velocity,
      angular_velocity = blended.angular_velocity,
    }

    -- Blend is complete
    if t >= 1.0 then
      state.is_blending = false
    end
  end

  return state.applied_transform
end

--- Set default blend duration
local function set_blend_duration(duration)
  M.default_blend_duration = math.max(0.01, duration)  -- Minimum 10ms
end

--- Get blend progress for debugging [0, 1]
local function get_blend_progress(id, current_time)
  local state = get_sync_state(id)
  if not state.is_blending then
    return 1.0
  end
  local elapsed = current_time - state.blend_start_time
  return math.max(0, math.min(1, elapsed / state.blend_duration))
end

--- Check if sync state has been initialized
local function is_initialized(id)
  local state = M.sync_states[id]
  return state ~= nil and state.base_timestamp > 0
end

--- Reset sync state for a vehicle
local function reset_sync_state(id)
  M.sync_states[id] = create_sync_state(id)
end

--- Cleanup stale sync states (prevent memory growth from despawned vehicles)
local function cleanup_stale_states(max_age)
  max_age = max_age or 30.0  -- Default: remove states older than 30 seconds
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

--- Manually refresh all sync states (debug/recovery command)
local function refresh_all_states()
  local count = 0
  for _ in pairs(M.sync_states) do
    count = count + 1
  end
  M.sync_states = {}
  return count
end

--- Export for network module
M.apply_snapshot = apply_snapshot
M.update_and_get_transform = update_and_get_transform
M.get_sync_state = get_sync_state
M.set_blend_duration = set_blend_duration
M.get_blend_progress = get_blend_progress
M.is_initialized = is_initialized
M.reset_sync_state = reset_sync_state
M.extrapolate_transform = extrapolate_transform
M.slerp_quaternion = slerp_quaternion
M.cleanup_stale_states = cleanup_stale_states  -- Optional: periodic cleanup
M.refresh_all_states = refresh_all_states  -- Optional: manual recovery command

return M
