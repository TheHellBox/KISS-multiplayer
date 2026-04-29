local M = {}

local nodes = {}

M.mass_cog_body = vec3(0, 0, 0)

local last_cog_compute_time = -math.huge
local COG_RECOMPUTE_INTERVAL_S = 0.2

local SEND_SMOOTH_RATE = 50.0
-- Sender-derived acceleration smoothing. The differential (Δv / Δt) is
-- inherently noise-amplifying at packet/send rate, so we lowpass at a
-- relatively conservative rate before transmission. Receivers prefer this
-- over their own (v_new - v_prev)/remote_dt path because the sender has
-- access to high-rate clean physics samples between transmits, and shipping
-- the derived acceleration removes the receiver-side 33x amplification.
local SEND_ACCEL_SMOOTH_RATE = 30.0
local smoothed_send_vel = nil
local smoothed_send_omega_body = nil
local last_smooth_call_time = nil
local prev_smoothed_send_vel = nil
local prev_smoothed_send_omega_world = nil
local smoothed_send_linear_accel = nil
local smoothed_send_angular_accel = nil
local send_timer = 0

local function get_body_gyro_local_omega()
  return vec3(
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity(),
    obj:getYawAngularVelocity()
  )
end

local function lowpass_dt(prev, target, dt, rate)
  if not prev then
    return vec3(target.x, target.y, target.z)
  end
  local alpha = math.min(rate * dt, 1.0)
  return vec3(
    prev.x + (target.x - prev.x) * alpha,
    prev.y + (target.y - prev.y) * alpha,
    prev.z + (target.z - prev.z) * alpha
  )
end

local function reset_send_smoothers()
  smoothed_send_vel = nil
  smoothed_send_omega_body = nil
  last_smooth_call_time = nil
  prev_smoothed_send_vel = nil
  prev_smoothed_send_omega_world = nil
  smoothed_send_linear_accel = nil
  smoothed_send_angular_accel = nil
end

-- Mass-weighted COG offset in body frame. The receiver uses this same body
-- offset to run the correction loop in COG-space instead of refnode-space.
local function compute_mass_cog_body()
  local total_mass = 0
  local cog_sum_x, cog_sum_y, cog_sum_z = 0, 0, 0

  for _, state in ipairs(nodes) do
    local mass = state.mass or 0
    if mass > 0 then
      local pos = obj:getNodePosition(state.cid)
      if pos then
        cog_sum_x = cog_sum_x + pos.x * mass
        cog_sum_y = cog_sum_y + pos.y * mass
        cog_sum_z = cog_sum_z + pos.z * mass
        total_mass = total_mass + mass
      end
    end
  end

  if total_mass < 1e-9 then
    M.mass_cog_body = vec3(0, 0, 0)
    return
  end

  local inv = 1 / total_mass
  local cog_world = vec3(cog_sum_x * inv, cog_sum_y * inv, cog_sum_z * inv)
  local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  M.mass_cog_body = cog_world:rotated(rot:inversed())
end

local function maybe_recompute_mass_cog_body()
  local now = os.clock()
  if now - last_cog_compute_time >= COG_RECOMPUTE_INTERVAL_S then
    compute_mass_cog_body()
    last_cog_compute_time = now
  end
end

local function get_mass_cog_body()
  return M.mass_cog_body or vec3(0, 0, 0)
end

local function onExtensionLoaded()
  nodes = {}
  last_cog_compute_time = -math.huge
  reset_send_smoothers()
  send_timer = 0

  if v and v.data and v.data.nodes then
    for _, node in pairs(v.data.nodes) do
      if node.cid ~= nil then
        nodes[#nodes + 1] = {
          cid = node.cid,
          mass = obj:getNodeMass(node.cid),
        }
      end
    end
  end

  compute_mass_cog_body()
end

local function onReset()
  last_cog_compute_time = -math.huge
  reset_send_smoothers()
  compute_mass_cog_body()
end

local function update_transform_info(_we_own_this_vehicle)
  -- Keep send and receive on the same rotation convention as the cluster API.
  local r = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local p = vec3(obj:getPosition())
  local raw_vel = vec3(obj:getVelocity())
  local raw_omega_body = get_body_gyro_local_omega()

  local now = obj:getSimTime() or os.clock()
  local smooth_dt = last_smooth_call_time and (now - last_smooth_call_time) or (1/60)
  last_smooth_call_time = now
  if smooth_dt > 0.1 then smooth_dt = 0.1 end

  smoothed_send_vel = lowpass_dt(smoothed_send_vel, raw_vel, smooth_dt, SEND_SMOOTH_RATE)
  smoothed_send_omega_body = lowpass_dt(smoothed_send_omega_body, raw_omega_body, smooth_dt, SEND_SMOOTH_RATE)

  local v_world = smoothed_send_vel
  local omega_world = smoothed_send_omega_body:rotated(r)

  maybe_recompute_mass_cog_body()
  local cog_world = get_mass_cog_body():rotated(r)
  local p_cog = p + cog_world
  local v_cog = v_world + cog_world:cross(omega_world)

  -- Derive sender-side acceleration from the smoothed COG-frame velocity /
  -- world-frame angular velocity and lowpass before transmit. Differentiating
  -- v_cog (not v_world) is what matches the wire payload — the receiver sees
  -- COG-frame velocity, so its second-order extrapolator wants COG-frame
  -- acceleration. Receivers then skip their (v_new - v_prev)/remote_dt path
  -- entirely, which avoids the ~1/remote_dt noise amplification.
  if prev_smoothed_send_vel ~= nil and smooth_dt > 1e-6 then
    local raw_send_linear_accel = vec3(
      (v_cog.x - prev_smoothed_send_vel.x) / smooth_dt,
      (v_cog.y - prev_smoothed_send_vel.y) / smooth_dt,
      (v_cog.z - prev_smoothed_send_vel.z) / smooth_dt
    )
    smoothed_send_linear_accel = lowpass_dt(smoothed_send_linear_accel, raw_send_linear_accel, smooth_dt, SEND_ACCEL_SMOOTH_RATE)
  end
  if prev_smoothed_send_omega_world ~= nil and smooth_dt > 1e-6 then
    local raw_send_angular_accel = vec3(
      (omega_world.x - prev_smoothed_send_omega_world.x) / smooth_dt,
      (omega_world.y - prev_smoothed_send_omega_world.y) / smooth_dt,
      (omega_world.z - prev_smoothed_send_omega_world.z) / smooth_dt
    )
    smoothed_send_angular_accel = lowpass_dt(smoothed_send_angular_accel, raw_send_angular_accel, smooth_dt, SEND_ACCEL_SMOOTH_RATE)
  end
  prev_smoothed_send_vel = vec3(v_cog.x, v_cog.y, v_cog.z)
  prev_smoothed_send_omega_world = vec3(omega_world.x, omega_world.y, omega_world.z)

  send_timer = now

  local throttle_input = electrics.values.throttle_input or 0
  local brake_input = electrics.values.brake_input or 0
  if electrics.values.gearboxMode == "arcade" and electrics.values.gearIndex < 0 then
    throttle_input, brake_input = brake_input, throttle_input
  end

  local input = {
    vehicle_id = obj:getID() or 0,
    throttle_input = throttle_input,
    brake_input = brake_input,
    clutch = electrics.values.clutch_input or 0,
    parkingbrake = electrics.values.parkingbrake_input or 0,
    steering_input = electrics.values.steering_input or 0,
  }
  local transform = {
    position = {p_cog.x, p_cog.y, p_cog.z},
    rotation = {r.x, r.y, r.z, r.w},
    velocity = {v_cog.x, v_cog.y, v_cog.z},
    angular_velocity = {omega_world.x, omega_world.y, omega_world.z},
    input = input,
    gearbox = kiss_gearbox.get_gearbox_data(),
    send_timer = send_timer,
    send_dt = smooth_dt,
  }
  if smoothed_send_linear_accel ~= nil then
    transform.acceleration = {smoothed_send_linear_accel.x, smoothed_send_linear_accel.y, smoothed_send_linear_accel.z}
  end
  if smoothed_send_angular_accel ~= nil then
    transform.angular_acceleration = {smoothed_send_angular_accel.x, smoothed_send_angular_accel.y, smoothed_send_angular_accel.z}
  end
  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", " .. string.format("%q", jsonEncode(transform)) .. ")")
end

local function send_vehicle_config()
  local r = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local p = obj:getPosition()
  local data = {
    position = {p.x, p.y, p.z},
    rotation = {r.x, r.y, r.z, r.w},
  }
  obj:queueGameEngineLua("vehiclemanager.send_vehicle_config_inner("..obj:getID()..", " .. string.format("%q", jsonEncode(v.config)) .. ", " .. string.format("%q", jsonEncode(data)) .. ")")
end

M.update_transform_info = update_transform_info
M.get_mass_cog_body = get_mass_cog_body
M.maybe_recompute_mass_cog_body = maybe_recompute_mass_cog_body
M.compute_mass_cog_body = compute_mass_cog_body
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.send_vehicle_config = send_vehicle_config

return M
