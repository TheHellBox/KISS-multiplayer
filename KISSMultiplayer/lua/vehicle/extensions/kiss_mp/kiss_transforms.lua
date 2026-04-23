-- KissMP Transforms - Direct state replay with prediction and blending
-- Phase 1b implementation

local M = {}
-- kiss_sync is loaded as a global vehicle extension module

M.debug = false  -- Enable debug logging
M.cooldown_timer = 2
M.sync_id = nil  -- Vehicle ID for sync state tracking

local function build_position_replay_cid_set(positions)
  local out = nil
  if not positions then return nil end
  for key in pairs(positions) do
    out = out or {}
    out[key] = true
    local cid = tonumber(key)
    if cid then
      out[cid] = true
    end
  end
  return out
end

local function get_layer1_centroid_body()
  if kiss_vehicle and kiss_vehicle.get_layer1_centroid_body then
    return kiss_vehicle.get_layer1_centroid_body()
  end
  return vec3(0, 0, 0)
end

local function get_body_gyro_local_omega()
  return vec3(
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity(),
    obj:getYawAngularVelocity()
  )
end

local function atan2(y, x)
  if math.atan2 then
    return math.atan2(y, x)
  end
  if x > 0 then
    return math.atan(y / x)
  elseif x < 0 and y >= 0 then
    return math.atan(y / x) + math.pi
  elseif x < 0 and y < 0 then
    return math.atan(y / x) - math.pi
  elseif x == 0 and y > 0 then
    return math.pi * 0.5
  elseif x == 0 and y < 0 then
    return -math.pi * 0.5
  end
  return 0
end

local function wrap_angle_pi(angle)
  while angle > math.pi do angle = angle - (2 * math.pi) end
  while angle < -math.pi do angle = angle + (2 * math.pi) end
  return angle
end

local function blend_scalar_toward_current(target, current, weight, deadband)
  local delta = target - current
  if math.abs(delta) < deadband then
    return current
  end
  return current + delta * weight
end

local function blend_angle_toward_current(target, current, weight, deadband)
  local delta = wrap_angle_pi(target - current)
  if math.abs(delta) < deadband then
    return current
  end
  return current + delta * weight
end

local function clear_drift_nudge_state()
  M.layer1_drift_nudge_time = 0
  M.layer1_drift_nudge_cooldown = 0
end

local function decay_toward_zero(value, amount)
  if value > 0 then
    return math.max(0, value - amount)
  elseif value < 0 then
    return math.min(0, value + amount)
  end
  return 0
end

local function clamp_planar_bias(x, y, max_len)
  local len_sq = x * x + y * y
  local max_sq = max_len * max_len
  if len_sq > max_sq and len_sq > 0 then
    local scale = max_len / math.sqrt(len_sq)
    return x * scale, y * scale
  end
  return x, y
end

local function clear_drift_integral_state()
  M.layer1_planar_bias_x = 0
  M.layer1_planar_bias_y = 0
  M.layer1_yaw_bias = 0
end

local function clear_course_heading_state()
  M.layer1_target_course_heading_xy = nil
  M.layer1_target_course_sample_pos = nil
  M.layer1_target_course_sample_age = 0
  M.layer1_current_course_heading_xy = nil
  M.layer1_current_course_sample_pos = nil
  M.layer1_current_course_sample_age = 0
  M.layer1_course_yaw_trim = 0
end

local function clear_drift_state()
  clear_drift_nudge_state()
  clear_drift_integral_state()
  clear_course_heading_state()
end

local function decay_drift_integral_state(dt)
  local planar_decay = dt * 0.35
  local yaw_decay = dt * math.rad(0.5)
  M.layer1_planar_bias_x = decay_toward_zero(M.layer1_planar_bias_x or 0, planar_decay)
  M.layer1_planar_bias_y = decay_toward_zero(M.layer1_planar_bias_y or 0, planar_decay)
  M.layer1_yaw_bias = decay_toward_zero(M.layer1_yaw_bias or 0, yaw_decay)
end

local function update_drift_integral(dt, current_centroid_pos, raw_centroid_pos,
                                     current_centroid_linvel, raw_centroid_linvel,
                                     current_local_omega, raw_local_omega,
                                     current_yaw, target_yaw)
  if not M.layer1_use_drift_integral then
    clear_drift_integral_state()
    return
  end

  local gain = M.layer1_drift_gain or 0
  if gain <= 0 then
    clear_drift_integral_state()
    return
  end

  local planar_error_x = raw_centroid_pos.x - current_centroid_pos.x
  local planar_error_y = raw_centroid_pos.y - current_centroid_pos.y
  local planar_error = math.sqrt(planar_error_x * planar_error_x + planar_error_y * planar_error_y)
  local yaw_error = wrap_angle_pi(target_yaw - current_yaw)
  local target_planar_speed = math.sqrt(raw_centroid_linvel.x * raw_centroid_linvel.x + raw_centroid_linvel.y * raw_centroid_linvel.y)
  local current_planar_speed = math.sqrt(current_centroid_linvel.x * current_centroid_linvel.x + current_centroid_linvel.y * current_centroid_linvel.y)
  local yaw_rate_error = math.abs(raw_local_omega.z - current_local_omega.z)
  local vertical_velocity_error = math.abs(raw_centroid_linvel.z - current_centroid_linvel.z)

  local calm = math.max(target_planar_speed, current_planar_speed) > 2.0
    and planar_error < 3.0
    and math.abs(yaw_error) < 0.35
    and yaw_rate_error < 1.0
    and vertical_velocity_error < 1.0
    and (M.rude_error_time or 0) <= 0

  if calm then
    M.layer1_planar_bias_x = (M.layer1_planar_bias_x or 0) + (planar_error_x * gain * dt)
    M.layer1_planar_bias_y = (M.layer1_planar_bias_y or 0) + (planar_error_y * gain * dt)
    M.layer1_planar_bias_x, M.layer1_planar_bias_y = clamp_planar_bias(
      M.layer1_planar_bias_x, M.layer1_planar_bias_y, 0.6
    )
    M.layer1_yaw_bias = clamp(
      (M.layer1_yaw_bias or 0) + (yaw_error * gain * dt),
      -math.rad(5),
      math.rad(5)
    )
  else
    decay_drift_integral_state(dt)
  end
end

local function apply_short_horizon_yaw_prediction(dt, target_yaw, current_yaw, raw_local_omega)
  if not M.layer1_enable_yaw_prediction then
    return target_yaw
  end

  if kiss_vehicle and kiss_vehicle.is_rigid_prop and kiss_vehicle.is_rigid_prop() then
    return target_yaw
  end

  local yaw_rate = raw_local_omega.z or 0
  local yaw_rate_mag = math.abs(yaw_rate)
  local yaw_error = math.abs(wrap_angle_pi(target_yaw - current_yaw))

  local calm = (M.rude_error_time or 0) <= 0
    and dt > 0
    and dt < 0.05
    and yaw_error < math.rad(35)
    and yaw_rate_mag > math.rad(1)
    and yaw_rate_mag < math.rad(140)

  if not calm then
    return target_yaw
  end

  local prediction_horizon = 0.06
  local prediction_blend = 0.6
  local max_delta = math.rad(10)
  local predicted_delta = clamp(yaw_rate * prediction_horizon, -max_delta, max_delta)

  return target_yaw + predicted_delta * prediction_blend
end

local function blend_angle(current, target, weight)
  if current == nil then
    return target
  end
  return current + wrap_angle_pi(target - current) * weight
end

local function update_smoothed_course_heading(dt, pos, linvel, sample_pos_key, sample_age_key, heading_key)
  local planar_speed = math.sqrt(linvel.x * linvel.x + linvel.y * linvel.y)

  M[sample_age_key] = (M[sample_age_key] or 0) + dt
  if not M[sample_pos_key] then
    M[sample_pos_key] = vec3(pos.x, pos.y, pos.z)
    M[sample_age_key] = 0
    return M[heading_key]
  end

  if (M[sample_age_key] or 0) < 0.2 then
    return M[heading_key]
  end

  local sample_pos = M[sample_pos_key]
  local dx = pos.x - sample_pos.x
  local dy = pos.y - sample_pos.y
  local displacement_sq = dx * dx + dy * dy
  local measured_heading = nil

  if displacement_sq > 0.25 then
    measured_heading = atan2(dy, dx)
  elseif planar_speed > 5.0 then
    measured_heading = atan2(linvel.y, linvel.x)
  end

  if measured_heading ~= nil then
    M[heading_key] = blend_angle(M[heading_key], measured_heading, 0.35)
  end

  M[sample_pos_key] = vec3(pos.x, pos.y, pos.z)
  M[sample_age_key] = 0
  return M[heading_key]
end

local function update_course_yaw_trim(dt, target_course_heading_xy, current_course_heading_xy,
                                      current_body_yaw, current_centroid_linvel,
                                      current_local_omega, current_vertical_speed)
  local gain = M.layer1_heading_hold_yaw_trim_gain or 0
  if gain <= 0 or target_course_heading_xy == nil or current_course_heading_xy == nil then
    M.layer1_course_yaw_trim = decay_toward_zero(M.layer1_course_yaw_trim or 0, dt * math.rad(12))
    return
  end

  local planar_speed = math.sqrt(
    current_centroid_linvel.x * current_centroid_linvel.x +
    current_centroid_linvel.y * current_centroid_linvel.y
  )
  local yaw_rate = math.abs(current_local_omega.z or 0)
  local body_course_error = math.abs(wrap_angle_pi(current_body_yaw - current_course_heading_xy))
  local speed_factor = clamp((planar_speed - 4.0) / 10.0, 0, 1)
  local body_course_factor = 1.0 - clamp(body_course_error / math.rad(25), 0, 1)
  local vertical_noise_factor = 1.0 - clamp(math.abs(current_vertical_speed or 0) / 2.0, 0, 1)
  local yaw_rate_factor = 1.0 - clamp(yaw_rate / 1.2, 0, 1)
  local heading_trust = speed_factor * body_course_factor * vertical_noise_factor * yaw_rate_factor
  local error = wrap_angle_pi(target_course_heading_xy - current_course_heading_xy)

  if heading_trust <= 0 or (M.rude_error_time or 0) > 0 then
    M.layer1_course_yaw_trim = decay_toward_zero(M.layer1_course_yaw_trim or 0, dt * math.rad(12))
    return
  end

  M.layer1_course_yaw_trim = clamp(
    (M.layer1_course_yaw_trim or 0) + (error * gain * dt * heading_trust),
    -math.rad(6),
    math.rad(6)
  )
end

local function filter_layer1_target(dt, raw_origin_pos, raw_rot, raw_origin_linvel, raw_local_omega)
  local current_rot = quat(obj:getRotation())
  local current_origin_pos = vec3(obj:getPosition())
  local current_origin_linvel = vec3(obj:getVelocity())
  local current_local_omega = get_body_gyro_local_omega()
  local centroid_body = get_layer1_centroid_body()

  local z_weight = M.layer1_z_weight
  local tilt_weight = M.layer1_tilt_weight
  local vz_weight = M.layer1_vz_weight
  local tilt_rate_weight = M.layer1_tilt_rate_weight
  local z_deadband = M.layer1_z_deadband
  local tilt_deadband = M.layer1_tilt_deadband
  local vz_deadband = M.layer1_vz_deadband
  local tilt_rate_deadband = M.layer1_tilt_rate_deadband

  if kiss_vehicle and kiss_vehicle.is_rigid_prop and kiss_vehicle.is_rigid_prop() then
    z_weight = math.min(z_weight, 0.1)
    tilt_weight = math.min(tilt_weight, 0.05)
    vz_weight = math.min(vz_weight, 0.1)
    tilt_rate_weight = math.min(tilt_rate_weight, 0.05)
  end

  local current_euler = current_rot:toEulerYXZ()
  local target_euler = raw_rot:toEulerYXZ()
  local current_centroid_offset = current_rot * centroid_body
  local raw_centroid_offset = raw_rot * centroid_body
  local current_centroid_pos = current_origin_pos + current_centroid_offset
  local raw_centroid_pos = raw_origin_pos + raw_centroid_offset
  local current_angvel = current_local_omega:rotated(current_rot)
  local current_centroid_linvel = current_origin_linvel + current_angvel:cross(current_centroid_offset)
  local raw_centroid_linvel = raw_origin_linvel + raw_local_omega:rotated(raw_rot):cross(raw_centroid_offset)
  local target_course_heading_xy = update_smoothed_course_heading(
    dt, raw_centroid_pos, raw_centroid_linvel,
    "layer1_target_course_sample_pos", "layer1_target_course_sample_age", "layer1_target_course_heading_xy"
  )
  local current_course_heading_xy = update_smoothed_course_heading(
    dt, current_centroid_pos, current_centroid_linvel,
    "layer1_current_course_sample_pos", "layer1_current_course_sample_age", "layer1_current_course_heading_xy"
  )

  update_drift_integral(
    dt,
    current_centroid_pos, raw_centroid_pos,
    current_centroid_linvel, raw_centroid_linvel,
    current_local_omega, raw_local_omega,
    current_euler.x, target_euler.x
  )
  update_course_yaw_trim(
    dt,
    target_course_heading_xy,
    current_course_heading_xy,
    current_euler.x,
    current_centroid_linvel,
    current_local_omega,
    current_centroid_linvel.z
  )

  local corrected_target_yaw = apply_short_horizon_yaw_prediction(
    dt,
    target_euler.x + (M.layer1_yaw_bias or 0) + (M.layer1_course_yaw_trim or 0),
    current_euler.x,
    raw_local_omega
  )

  local filtered_pitch = blend_angle_toward_current(target_euler.y, current_euler.y, tilt_weight, tilt_deadband)
  local filtered_roll = blend_angle_toward_current(target_euler.z, current_euler.z, tilt_weight, tilt_deadband)
  local filtered_rot = quatFromEuler(filtered_pitch, filtered_roll, corrected_target_yaw)
  local filtered_local_omega = vec3(
    blend_scalar_toward_current(raw_local_omega.x, current_local_omega.x, tilt_rate_weight, tilt_rate_deadband),
    blend_scalar_toward_current(raw_local_omega.y, current_local_omega.y, tilt_rate_weight, tilt_rate_deadband),
    raw_local_omega.z
  )
  local filtered_angvel = filtered_local_omega:rotated(filtered_rot)
  local filtered_centroid_pos = vec3(
    raw_centroid_pos.x + (M.layer1_planar_bias_x or 0),
    raw_centroid_pos.y + (M.layer1_planar_bias_y or 0),
    blend_scalar_toward_current(raw_centroid_pos.z, current_centroid_pos.z, z_weight, z_deadband)
  )
  local filtered_centroid_linvel = vec3(
    raw_centroid_linvel.x,
    raw_centroid_linvel.y,
    blend_scalar_toward_current(raw_centroid_linvel.z, current_centroid_linvel.z, vz_weight, vz_deadband)
  )

  return filtered_centroid_pos, filtered_rot, filtered_centroid_linvel, filtered_angvel
end

-- Get current transform from sync module (includes prediction + blending)
local function get_synced_transform(current_time)
  if not M.sync_id then return nil end
  return kiss_sync.update_and_get_transform(M.sync_id, current_time)
end

local function clear_cached_nodes()
  M.cached_positions_dev = nil
  M.cached_velocities_dev = nil
  M.cached_position_replay_cids = nil
end

local function try_drift_nudge(filtered_centroid_pos, filtered_rot, filtered_centroid_linvel, dt)
  if M.layer1_use_drift_integral then
    clear_drift_nudge_state()
    return false
  end

  local gain = M.layer1_drift_gain or 0
  if gain <= 0 then
    clear_drift_nudge_state()
    return false
  end

  if kiss_vehicle and kiss_vehicle.is_rigid_prop and kiss_vehicle.is_rigid_prop() then
    clear_drift_nudge_state()
    return false
  end

  M.layer1_drift_nudge_cooldown = math.max(0, (M.layer1_drift_nudge_cooldown or 0) - dt)

  local current_rot = quat(obj:getRotation())
  local current_origin_pos = vec3(obj:getPosition())
  local current_origin_linvel = vec3(obj:getVelocity())
  local current_centroid_pos = current_origin_pos + current_rot * get_layer1_centroid_body()
  local current_euler = current_rot:toEulerYXZ()
  local target_euler = filtered_rot:toEulerYXZ()

  local planar_error_x = filtered_centroid_pos.x - current_centroid_pos.x
  local planar_error_y = filtered_centroid_pos.y - current_centroid_pos.y
  local planar_error = math.sqrt(planar_error_x * planar_error_x + planar_error_y * planar_error_y)
  local yaw_error = math.abs(wrap_angle_pi(target_euler.x - current_euler.x))
  local target_planar_speed = math.sqrt(
    filtered_centroid_linvel.x * filtered_centroid_linvel.x
    + filtered_centroid_linvel.y * filtered_centroid_linvel.y
  )
  local current_planar_speed = math.sqrt(
    current_origin_linvel.x * current_origin_linvel.x
    + current_origin_linvel.y * current_origin_linvel.y
  )

  local calm = (M.rude_error_time or 0) <= 0
    and math.max(target_planar_speed, current_planar_speed) > 2.0
    and planar_error > 1.5
    and planar_error < 6.0
    and yaw_error < math.rad(20)
    and math.abs(current_origin_linvel.z) < 1.5

  if not calm then
    M.layer1_drift_nudge_time = math.max(0, (M.layer1_drift_nudge_time or 0) - (dt * 2.0))
    return false
  end

  M.layer1_drift_nudge_time = (M.layer1_drift_nudge_time or 0) + dt
  if (M.layer1_drift_nudge_time or 0) < 0.75 or (M.layer1_drift_nudge_cooldown or 0) > 0 then
    return false
  end

  local nudge_len = clamp(planar_error * gain * 2.0, 0, 0.05)
  if nudge_len <= 1e-4 or planar_error <= 1e-4 then
    return false
  end

  local dir_x = planar_error_x / planar_error
  local dir_y = planar_error_y / planar_error
  local nudged_origin = vec3(
    current_origin_pos.x + dir_x * nudge_len,
    current_origin_pos.y + dir_y * nudge_len,
    current_origin_pos.z
  )

  obj:queueGameEngineLua(
    "be:getObjectByID("..obj:getID().."):setPositionNoPhysicsReset(Point3F("
    ..nudged_origin.x..","..nudged_origin.y..","..nudged_origin.z.."))"
  )

  M.layer1_drift_nudge_time = 0
  M.layer1_drift_nudge_cooldown = 0.75
  return true
end

-- Handle large corrections (teleport prevention) using filtered centroid/path
-- error rather than raw origin mismatch. This avoids snapping vehicles that are
-- still visually on track after the follower-side filtering.
local function try_rude(filtered_centroid_pos, filtered_rot, dt)
  local current_rot = quat(obj:getRotation())
  local current_centroid_pos = vec3(obj:getPosition()) + current_rot * get_layer1_centroid_body()
  local current_euler = current_rot:toEulerYXZ()
  local target_euler = filtered_rot:toEulerYXZ()
  local planar_error_x = filtered_centroid_pos.x - current_centroid_pos.x
  local planar_error_y = filtered_centroid_pos.y - current_centroid_pos.y
  local planar_error = math.sqrt(planar_error_x * planar_error_x + planar_error_y * planar_error_y)
  local vertical_error = math.abs(filtered_centroid_pos.z - current_centroid_pos.z)
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

  clear_cached_nodes()
  clear_drift_state()
  M.rude_error_time = 0

  local target_origin = filtered_centroid_pos - filtered_rot * get_layer1_centroid_body()
  obj:queueGameEngineLua(
    "be:getObjectByID("..obj:getID().."):setPositionRotation("
    ..target_origin.x..","..target_origin.y..","..target_origin.z..","
    ..filtered_rot.x..","..filtered_rot.y..","..filtered_rot.z..","..filtered_rot.w..")"
  )
  return true
end

local function draw_debug(synced_transform)
  obj.debugDrawProxy:drawSphere(0.3, synced_transform.position:toFloat3(), color(0,255,0,100))
  local current_pos = vec3(obj:getPosition())
  obj.debugDrawProxy:drawSphere(0.3, current_pos:toFloat3(), color(255,0,0,100))
  -- Draw blend progress if active
  local blend_progress = kiss_sync.get_blend_progress(M.sync_id, M.last_update_time or 0)
  if blend_progress < 1.0 then
    obj.debugDrawProxy:drawText("Blend: " .. math.floor(blend_progress * 100) .. "%", current_pos:toFloat3(), color(255,255,0,255))
  end
end

local function update(dt)
  -- DEBUG: Log update call
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

  -- Get synced transform from sync module (includes prediction + active blending)
  local current_time = os.clock()
  M.last_update_time = current_time

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

  local cluster_centroid_pos, cluster_rot, cluster_linvel, cluster_angvel = filter_layer1_target(
    dt,
    synced_transform.position,
    synced_transform.rotation,
    synced_transform.velocity or vec3(0, 0, 0),
    synced_transform.angular_velocity or vec3(0, 0, 0)
  )

  try_drift_nudge(cluster_centroid_pos, cluster_rot, cluster_linvel, dt)

  -- Handle large corrections (teleport prevention) after filtering.
  if try_rude(cluster_centroid_pos, cluster_rot, dt) then
    if M.debug then
      print("[kiss_transforms.update] try_rude triggered - filtered centroid reset applied")
      draw_debug(synced_transform)
    end
    return
  end
  local layer1_pull_gain = M.layer1_pull_gain
  local layer1_dp_deadband = M.layer1_dp_deadband
  local layer1_dv_deadband = M.layer1_dv_deadband
  local layer1_max_dv = M.layer1_max_dv

  if kiss_vehicle and kiss_vehicle.is_rigid_prop and kiss_vehicle.is_rigid_prop() then
    layer1_pull_gain = 0
    layer1_dp_deadband = math.max(layer1_dp_deadband, 0.05)
    layer1_dv_deadband = math.max(layer1_dv_deadband, 0.2)
    layer1_max_dv = math.min(layer1_max_dv, 2.0)
  end

  -- Layer 1: filtered rigid pull toward the currently applied cluster target
  -- from kiss_sync.
  if kiss_vehicle and kiss_vehicle.apply_rigid_pull then
    kiss_vehicle.apply_rigid_pull(
      cluster_centroid_pos, cluster_rot,
      cluster_linvel, cluster_angvel,
      nil,
      layer1_pull_gain, layer1_dp_deadband, layer1_dv_deadband, layer1_max_dv
    )
  end

  if kiss_vehicle and kiss_vehicle.draw_layer1_debug then
    kiss_vehicle.draw_layer1_debug()
  end

  if M.debug then
    draw_debug(synced_transform)
  end
end

M.cached_positions_dev = nil
M.cached_velocities_dev = nil
M.cached_position_replay_cids = nil

-- Layer 1 tuning (mirrors Layer 2's knobs — can split later if needed).
M.layer1_pull_gain = 30
M.layer1_dp_deadband = 0.01
M.layer1_dv_deadband = 0.1
M.layer1_max_dv = 10.0
M.layer1_z_weight = 0.2
M.layer1_tilt_weight = 0.15
M.layer1_vz_weight = 0.25
M.layer1_tilt_rate_weight = 0.2
M.layer1_z_deadband = 0.03
M.layer1_tilt_deadband = math.rad(1.5)
M.layer1_vz_deadband = 0.15
M.layer1_tilt_rate_deadband = 0.15
M.layer1_drift_gain = 0.02
M.layer1_use_drift_integral = false
M.layer1_enable_yaw_prediction = false
M.layer1_drift_nudge_time = 0
M.layer1_drift_nudge_cooldown = 0
M.layer1_planar_bias_x = 0
M.layer1_planar_bias_y = 0
M.layer1_yaw_bias = 0
M.layer1_target_course_heading_xy = nil
M.layer1_target_course_sample_pos = nil
M.layer1_target_course_sample_age = 0
M.layer1_current_course_heading_xy = nil
M.layer1_current_course_sample_pos = nil
M.layer1_current_course_sample_age = 0
M.layer1_course_yaw_trim = 0
M.layer1_heading_hold_yaw_trim_gain = 0.75
M.rude_error_time = 0

local function set_layer1_tuning(pull_gain, dp_deadband, dv_deadband, max_dv)
  if pull_gain ~= nil then M.layer1_pull_gain = math.max(0, pull_gain) end
  if dp_deadband ~= nil then M.layer1_dp_deadband = math.max(0, dp_deadband) end
  if dv_deadband ~= nil then M.layer1_dv_deadband = math.max(0, dv_deadband) end
  if max_dv ~= nil then M.layer1_max_dv = math.max(0.001, max_dv) end
end

local function set_filter_tuning(z_weight, tilt_weight, vz_weight, tilt_rate_weight,
                                 z_deadband, tilt_deadband, vz_deadband, tilt_rate_deadband)
  if z_weight ~= nil then M.layer1_z_weight = clamp(z_weight, 0, 1) end
  if tilt_weight ~= nil then M.layer1_tilt_weight = clamp(tilt_weight, 0, 1) end
  if vz_weight ~= nil then M.layer1_vz_weight = clamp(vz_weight, 0, 1) end
  if tilt_rate_weight ~= nil then M.layer1_tilt_rate_weight = clamp(tilt_rate_weight, 0, 1) end
  if z_deadband ~= nil then M.layer1_z_deadband = math.max(0, z_deadband) end
  if tilt_deadband ~= nil then M.layer1_tilt_deadband = math.max(0, tilt_deadband) end
  if vz_deadband ~= nil then M.layer1_vz_deadband = math.max(0, vz_deadband) end
  if tilt_rate_deadband ~= nil then M.layer1_tilt_rate_deadband = math.max(0, tilt_rate_deadband) end
end

local function set_drift_tuning(drift_gain)
  if drift_gain ~= nil then
    M.layer1_drift_gain = math.max(0, drift_gain)
  end
end

local function set_bias_tuning(drift_bias_gain)
  set_drift_tuning(drift_bias_gain)
end

local function set_drift_mode(use_integral)
  if use_integral ~= nil then
    M.layer1_use_drift_integral = use_integral and true or false
    clear_drift_state()
  end
end

local function set_prediction_tuning(enable_yaw_prediction)
  if enable_yaw_prediction ~= nil then
    M.layer1_enable_yaw_prediction = enable_yaw_prediction and true or false
  end
end

local function set_heading_hold_tuning(heading_hold_yaw_trim_gain)
  if heading_hold_yaw_trim_gain ~= nil then
    M.layer1_heading_hold_yaw_trim_gain = math.max(0, heading_hold_yaw_trim_gain)
  end
end

-- Apply authoritative snapshot from wire. Runs ONCE per received packet
-- (queued by kisstransform.update_vehicle_transform). Just caches — no
-- force application here. Force pulls happen every Lua frame from update(dt)
-- so the correction is sustained and doesn't depend on packet cadence.
local function set_target_transform(raw)
  local transform = jsonDecode(raw)

  if transform.owner then
    M.sync_id = transform.owner
  end
  if not M.sync_id then return end

  local current_time = os.clock()
  kiss_sync.apply_snapshot(
    M.sync_id, transform,
    transform.sent_at or current_time,
    transform.generation or 0,
    current_time, 0.15
  )

  clear_cached_nodes()
end

local function onExtensionLoaded()
  -- Initialize sync state with current vehicle position
  M.sync_id = obj:getID()
  local current_pos = vec3(obj:getPosition())
  local current_rot = quat(obj:getRotation())

  -- Set initial state to avoid snap on first update
  local current_time = os.clock()
  local initial_transform = {
    position = {current_pos.x, current_pos.y, current_pos.z},
    rotation = {current_rot.x, current_rot.y, current_rot.z, current_rot.w},
    velocity = {0, 0, 0},
    angular_velocity = {0, 0, 0},
  }
  kiss_sync.apply_snapshot(M.sync_id, initial_transform, current_time, 0, current_time, 0)

  clear_drift_state()
  M.rude_error_time = 0
  M.cooldown_timer = 1.5
end

local function onReset()
  -- Reset sync state on vehicle reset
  if M.sync_id then
    kiss_sync.reset_sync_state(M.sync_id)
  end
  clear_cached_nodes()
  clear_drift_state()
  M.rude_error_time = 0
  M.cooldown_timer = 0.2
end

-- Export functions
M.set_target_transform = set_target_transform
M.update = update
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.get_synced_transform = get_synced_transform
M.clear_cached_nodes = clear_cached_nodes
M.set_layer1_tuning = set_layer1_tuning
M.set_filter_tuning = set_filter_tuning
M.set_drift_tuning = set_drift_tuning
M.set_bias_tuning = set_bias_tuning
M.set_drift_mode = set_drift_mode
M.set_prediction_tuning = set_prediction_tuning
M.set_heading_hold_tuning = set_heading_hold_tuning

return M
