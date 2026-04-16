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

-- PID integral state for lateral self-centering on the front-puller path.
-- Accumulates perpendicular-to-heading position error in metres·seconds
-- so the integral term can eliminate steady-state lateral drift that the
-- P term can't close. Clamped to prevent windup. Reset on cooldown and
-- on try_rude teleports.
M.lateral_integral = 0
local LATERAL_INTEGRAL_CLAMP = 5.0  -- m·s, anti-windup

-- Debug: last computed forces for visualization
local last_linear_force = vec3(0, 0, 0)
local last_angular_force = vec3(0, 0, 0)
local last_position_delta = vec3(0, 0, 0)
local last_velocity_diff = vec3(0, 0, 0)
local last_update_skipped = false
local log_timer = 0
local LOG_INTERVAL = 1.0 / 33.0 -- log every tick (~30ms)

-- Caps for prediction extrapolation. These are ceilings to prevent
-- pathologically stale data (dropped packets, hitches) from running
-- extrapolation wild — normal latency passes through unclipped, so a
-- 20ms-RTT LAN player and a 150ms-RTT internet player both get an
-- appropriately sized window without a config knob.
--
-- Separate caps because linear and rotational extrapolation have
-- different noise profiles:
--   * Linear: recv.velocity is derivable from position samples but
--     amplified at turn transitions and wheel chatter. Over-extrapolating
--     linearly feeds forward bias into the PD and can cause jackknife
--     / teleport loops on coupled rigs. Stay conservative.
--   * Rotational: angular velocity is measured more cleanly and ω is
--     smoother than v during steady turns. Late-turning on remote cars
--     at >50ms latency is directly caused by insufficient rotation
--     extrapolation, so allow a larger window here.
local PREDICT_TIME_CAP_LIN = 0.1
local PREDICT_TIME_CAP_ROT = 0.2

-- Prediction enabled flag. Set by update() from the tuning pipeline.
-- When false, predict() skips all extrapolation and sets target directly
-- from received_transform. Used to A/B test whether prediction is
-- adding value or adding error on the current tuning.
local prediction_enabled = true

local function predict(dt)
  if not prediction_enabled then
    -- No extrapolation: target = last received state, exactly.
    M.target_transform.position = vec3(M.received_transform.position)
    M.target_transform.velocity = vec3(M.received_transform.velocity)
    M.target_transform.rotation = quat(M.received_transform.rotation)
    return
  end
  local tp_lin = math.min(M.received_transform.time_past, PREDICT_TIME_CAP_LIN)
  local tp_rot = math.min(M.received_transform.time_past, PREDICT_TIME_CAP_ROT)
  -- End velocity at "now": v0 + a·t
  M.target_transform.velocity = M.received_transform.velocity + M.received_transform.acceleration * tp_lin
  -- Correct kinematic position extrapolation: p = p0 + v0·t + ½·a·t²
  -- The previous formula used end-velocity × time_past, which produced
  -- p0 + v0·t + a·t² — double the acceleration contribution. That
  -- velocity-sign-dependent error is why driving backward appears to
  -- "correct" forward-drive position drift: the doubled-accel overshoot
  -- flips sign with velocity direction and cancels the accumulated error.
  local distance =  M.target_transform.position:distance(vec3(obj:getPosition()))
  local p = M.received_transform.position
    + M.received_transform.velocity * tp_lin
    + M.received_transform.acceleration * (0.5 * tp_lin * tp_lin)
  if distance < 2 then
    M.target_transform.position = lerp(M.target_transform.position, p, clamp(M.lerp_factor * dt, 0.00001, 1))
  else
    M.target_transform.position = p
  end

  -- Rotation extrapolation. Without this, target_rotation is always stale
  -- by time_past seconds, which creates a mismatch against the linear
  -- extrapolation above: the position target is "where you'll be" but the
  -- rotation target is "where you were". When the owner is turning, the
  -- remote PD pulls the chassis toward a linear target computed along the
  -- old heading — causing lateral scrub at the refnode that propagates
  -- through the coupler chain as trailer drift / jackknife.
  --
  -- Axis-angle construction: "rotate by ω for Δt seconds" is a single
  -- rotation around axis ω̂ by angle |ω|·Δt. Exact for constant angular
  -- velocity, no Euler coupling error, no slot-order ambiguity — the
  -- quaternion is built directly from the ω vector components without
  -- any swizzle. Avoids the documented BeamNG trap where quatFromEuler
  -- and toEulerYXZ use different vec3 slot conventions.
  --
  -- Received angular_velocity comes from the network as the body-frame
  -- vector the owner sampled from obj:get{Pitch,Roll,Yaw}AngularVelocity,
  -- packed into (.x, .y, .z). Since axis-angle is frame-agnostic as long
  -- as input and output share a frame, the body-frame ω produces a
  -- body-frame delta quaternion, which we right-multiply onto the
  -- current body rotation — correct for body-frame angular velocity.
  local av = M.received_transform.angular_velocity
  local wx, wy, wz = av.x, av.y, av.z
  local speed = math.sqrt(wx * wx + wy * wy + wz * wz)
  local q_delta
  if speed > 1e-8 then
    local angle = speed * tp_rot
    local half = angle * 0.5
    local s = math.sin(half) / speed
    q_delta = quat(wx * s, wy * s, wz * s, math.cos(half))
  else
    q_delta = quat(0, 0, 0, 1)
  end
  M.target_transform.rotation = (quat(M.received_transform.rotation) * q_delta):normalized()
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

-- ==================================================================
-- Phase 2: cluster-sync early path
-- ==================================================================
-- When tun_cluster_sync_enabled is true AND cluster_spawn has
-- populated cluster_state.clusters AND tun_cluster_sync_force_fallback
-- is false, the cluster_receiver runs BEFORE any legacy force code
-- and we return early. The degenerate single-cluster case behaves
-- like a per-node generalization of the front-puller (the whole
-- vehicle is one rigid cluster).
--
-- Any failure condition (no clusters, no target yet, missing offsets)
-- falls through to the legacy path so Phase 2 cannot regress on
-- vehicles whose discovery hasn't finished or that failed discovery
-- altogether. Legacy is still the safe default.
local function try_apply_cluster_sync(dt, enable_flag, force_fallback)
  if dt <= 0 or dt > 0.1 then return false end
  if enable_flag ~= true then return false end
  if force_fallback == true then return false end
  if not cluster_state or not cluster_state.clusters then return false end
  if #cluster_state.clusters == 0 then return false end
  if not cluster_receiver then return false end

  -- Build the target pose. Position / rotation / linear velocity come
  -- from M.target_transform (already extrapolated forward by predict()
  -- to approximately "now"). Angular velocity comes from
  -- M.received_transform because M.target_transform.angular_velocity
  -- is never written by predict() — legacy code uses it only as a
  -- damping term where its zero value is harmless; for cluster sync
  -- we need the real owner-sampled ω, which is in received_transform.
  -- Phase 2 acts only on ROOT clusters (degenerate single-cluster
  -- case); child clusters of multi-cluster vehicles fall through to
  -- legacy until Phase 3 wires parent-relative frame composition.
  local combined = {
    position         = M.target_transform.position,
    rotation         = M.target_transform.rotation,
    velocity         = M.target_transform.velocity,
    angular_velocity = M.received_transform.angular_velocity,
  }
  local pose = cluster_receiver.target_from_transform(combined)
  if not pose then return false end

  local base_pos = vec3(obj:getPosition())
  local get_pos = function(cid)
    local ok, off = pcall(function() return vec3(obj:getNodePosition(cid)) end)
    if not ok or not off then return base_pos end
    return base_pos + off
  end
  local get_vel = function(cid)
    local ok, v = pcall(function() return vec3(obj:getNodeVelocityVector(cid)) end)
    if not ok or not v then return vec3(0, 0, 0) end
    return v
  end
  local apply_force = function(cid, f)
    obj:applyForceVector(cid, f)
  end

  local any_applied = false
  for _, c in ipairs(cluster_state.clusters) do
    if c.enabled and c.is_root and c.masses and c.node_offsets_local then
      cluster_receiver.apply_cluster_forces(
        c, pose, c.masses, dt, cluster_state.const,
        get_pos, get_vel, apply_force
      )
      any_applied = true
    end
  end
  return any_applied
end

local function update(dt, skip_rude, ang_scale, truck_mass, enable_deadband,
                      tun_Kp_yaw, tun_Kd_yaw, tun_force_cap_g, tun_speed_gate_high,
                      use_front_puller_solo, tun_lateral_pd_scale, tun_speed_gate_low,
                      tun_lateral_integral_gain, tun_prediction_enabled,
                      tun_cluster_sync_enabled, tun_cluster_sync_force_fallback)
  -- Set module-level flag that predict() reads, before calling it.
  if tun_prediction_enabled == false then
    prediction_enabled = false
  else
    prediction_enabled = true
  end
  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    M.lateral_integral = 0  -- anti-windup: clear accumulated error during cooldown
    return
  end
  if dt > 0.1 then return end
  M.received_transform.time_past = clamp(M.received_transform.time_past + dt, 0, 0.5)
  predict(dt)

  -- try_rude BEFORE cluster sync. When the owner map-teleports their
  -- vehicle, the remote's position error can be 100m+. Without this
  -- snap, cluster sync's per-node forces (pos_err × KP_POS → absurd
  -- velocity → beam-breaking forces) would rip the car apart. The 6m
  -- snap brings the remote close enough that subsequent forces are
  -- gentle. After a snap, set a brief cooldown so the beam solver can
  -- settle before per-node forces resume — without this the first
  -- post-snap tick sees a large velocity mismatch (vehicle is at zero
  -- velocity after snap but target says full speed) and forces still
  -- destroy the car.
  if not skip_rude and try_rude() then
    M.lateral_integral = 0
    cooldown_timer = 0.5  -- half second to settle after teleport snap
    return
  end

  -- Phase 2 cluster-sync branch. If conditions are met, the cluster
  -- receiver applies per-node velocity-matching forces for every
  -- root cluster and we return BEFORE legacy force code. Legacy
  -- path is the fallback when cluster sync is disabled, forced to
  -- fallback, or when discovery hasn't completed yet.
  if try_apply_cluster_sync(dt, tun_cluster_sync_enabled, tun_cluster_sync_force_fallback) then
    M.lateral_integral = 0  -- cluster path owns the force; clear legacy integral
    return
  end

  local force = M.force
  local ang_force = M.ang_force

  local c_ang = -math.sqrt(4 * ang_force)

  local velocity_difference = M.target_transform.velocity - vec3(obj:getVelocity())
  local position_delta = M.target_transform.position - vec3(obj:getPosition())
  -- Deadband for plain uncoupled vehicles: if we're already tracking the
  -- target closely (small position error AND small velocity error), skip
  -- linear correction entirely. Stops cargo on tilt decks from being
  -- continuously jiggled by PD forces when it's already basically where
  -- it should be. ONLY set by kisstransform GE side on the non-coupled,
  -- non-truck branch — coupled rigs NEVER get here.
  local deadband_active = false
  if enable_deadband
    and position_delta:length() < 0.15
    and velocity_difference:length() < 0.5 then
    deadband_active = true
  end
  --position_delta = position_delta:normalized() * math.pow(position_delta:length(), 2)
  local linear_force = (velocity_difference + position_delta * force) * dt * 5
  if linear_force:length() > 10 then
    linear_force = linear_force:normalized() * 10
  end
  if deadband_active then
    linear_force = vec3(0, 0, 0)
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
  -- Previously multiplied linear_force by ang_scale (mass ratio) on
  -- coupled trucks to protect the hitch from linear PD pushes. That's
  -- obsolete now that the coupled path doesn't apply angular torque via
  -- the cross-product whip — the hitch is only indirectly affected by
  -- linear pushes through chassis beams, and softening linear PD just
  -- makes position drift grow unbounded on heavy rigs. Linear PD at
  -- full strength.

  local local_ang_vel = vec3(
    obj:getYawAngularVelocity(),
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity()
  )

  -- =====================================================================
  -- FRONT-PULLER PATH: lateral force at front chassis subset
  -- =====================================================================
  -- Entered by coupled trucks (skip_rude=true) always, and by solo
  -- non-coupled vehicles when the use_front_puller_solo toggle is on.
  -- Early return so the legacy impulsive angular-torque path below never
  -- runs on these vehicles. At speed we use a lateral force at a front
  -- chassis subset (no hitch whip); low-speed heading drift is accepted
  -- as a trade-off — corrects on first motion via tire dynamics.
  if skip_rude or use_front_puller_solo then
    -- Yaw error via forward-vector cross product. Stable through ±π wrap,
    -- no dependence on toEulerYXZ slot conventions. vec3(0, 1, 0) is
    -- forward in the engine rotation frame (matches existing code in
    -- kisstransform.lua that uses this convention).
    local cur_rot_q = quat(obj:getRotation())
    local fwd_cur = cur_rot_q * vec3(0, 1, 0)
    local fwd_tgt = quat(M.target_transform.rotation) * vec3(0, 1, 0)
    fwd_cur.z = 0
    fwd_tgt.z = 0
    local cur_len = fwd_cur:length()
    local tgt_len = fwd_tgt:length()
    local yaw_err = 0
    if cur_len > 0.01 and tgt_len > 0.01 then
      fwd_cur = fwd_cur * (1 / cur_len)
      fwd_tgt = fwd_tgt * (1 / tgt_len)
      local cross_z = fwd_cur.x * fwd_tgt.y - fwd_cur.y * fwd_tgt.x
      local dot = fwd_cur.x * fwd_tgt.x + fwd_cur.y * fwd_tgt.y
      yaw_err = math.atan2(cross_z, dot)
    end

    -- Tuning (live from kisstuning GE state, passed as trailing args)
    local Kp_yaw = tun_Kp_yaw or 1.0
    local Kd_yaw = tun_Kd_yaw or 0.35
    local force_cap_accel = tun_force_cap_g or 0.6  -- in m/s²
    local speed_gate_high = tun_speed_gate_high or 5.5
    -- Low gate is the speed below which the front-puller goes to zero.
    -- Now user-tunable (default 1.5 m/s). Lower values let the mechanism
    -- keep correcting heading deep into the deceleration phase so heading
    -- is closer to target when the vehicle comes to rest.
    local speed_gate_low = tun_speed_gate_low or 1.5
    local speed_gate_span = math.max(0.1, speed_gate_high - speed_gate_low)

    -- Signed forward speed via projection onto current forward vector.
    -- Positive = driving forward. Reverse speed pins speed_gain to 0.
    local velocity_world = vec3(obj:getVelocity())
    local fwd_velocity = velocity_world:dot(fwd_cur)
    local speed_gain = clamp((fwd_velocity - speed_gate_low) / speed_gate_span, 0.0, 1.0)

    -- Yaw rate error (swizzled target vs. local). local_ang_vel.x is yaw
    -- (constructed from getYawAngularVelocity as the first component).
    -- Network angular_velocity is packed (pitch, roll, yaw) → .z is yaw.
    local target_ang_vel_yaw = M.target_transform.angular_velocity.z
    local yaw_rate_err = target_ang_vel_yaw - local_ang_vel.x

    -- ---------- FAST-SPEED PATH: lateral force at front chassis ----------
    local pd_signal = Kp_yaw * yaw_err + Kd_yaw * yaw_rate_err

    local mass_for_force = truck_mass or 2000
    -- NOTE: ang_scale is intentionally NOT applied here. The force cap
    -- below (force_cap_accel × mass) is already mass-aware. Multiplying
    -- by ang_scale would leave heavy rigs with ~0.05 × the intended
    -- correction force — not enough to ever close the heading error.
    local force_mag = pd_signal * mass_for_force * speed_gain * ping_scale

    -- Hard cap: peak chassis lateral acceleration × vehicle mass (Newtons)
    local FORCE_CAP = force_cap_accel * mass_for_force
    if math.abs(force_mag) > FORCE_CAP then
      force_mag = FORCE_CAP * (force_mag > 0 and 1 or -1)
    end

    -- Force direction = -right_world (+X engine frame = right). Positive
    -- yaw_err means target is counterclockwise from current → push front
    -- of truck to the left → force in -right direction.
    local right_world = cur_rot_q * vec3(1, 0, 0)
    right_world.z = 0
    local rw_len = right_world:length()
    local lat_force_x, lat_force_y = 0, 0
    if rw_len > 0.01 then
      right_world = right_world * (1 / rw_len)
      lat_force_x = right_world.x * (-force_mag)
      lat_force_y = right_world.y * (-force_mag)
    end

    -- Attenuate lateral P + add lateral integral term for self-centering.
    --
    -- The P term alone (with lateral_pd_scale ~0.3) closes most drift but
    -- can leave a steady-state offset that the P can't eliminate: a
    -- constant external force (hitch drag, tire scrub, physics imbalance)
    -- holds a residual error that P goes to zero against. The integral
    -- term accumulates lateral error over time until the integral force
    -- eliminates the residual, then holds whatever force is needed.
    --
    -- Integrated axis: vehicle-right (perpendicular to forward in the
    -- horizontal plane). We already have right_world from the yaw-force
    -- math above.
    local lateral_scale_base = tun_lateral_pd_scale or 0.2
    local Ki_lateral = tun_lateral_integral_gain or 0.5
    local mass_for_i = truck_mass or 2000

    -- Auto-balance: the effective lateral P scale depends on how hard
    -- the vehicle is currently yawing. During a turn, high yaw rate
    -- means we want soft lateral P so it doesn't fight the tires and
    -- drag the chassis inward. On a straight line, low yaw rate means
    -- we want strong lateral P to close residual drift quickly.
    -- YAW_RATE_REF is the rate at which we hit the full soft floor
    -- (configured at ~45°/s = 0.78 rad/s, which is moderate cornering).
    local YAW_RATE_REF = 0.78
    local yaw_rate_norm = clamp(math.abs(local_ang_vel.x) / YAW_RATE_REF, 0, 1)
    -- At yaw rate 0 → lateral_scale = 1.0 (full strength)
    -- At yaw rate >= YAW_RATE_REF → lateral_scale = lateral_scale_base (soft floor)
    local lateral_scale = lateral_scale_base + (1 - lateral_scale_base) * (1 - yaw_rate_norm)

    if fwd_cur and fwd_cur:length() > 0.99 and rw_len and rw_len > 0.99 then
      -- Decompose linear_force horizontal part into forward/right scalars
      local lin_fwd_comp = linear_force.x * fwd_cur.x + linear_force.y * fwd_cur.y
      local lin_right_comp = linear_force.x * right_world.x + linear_force.y * right_world.y

      -- Attenuated P lateral (yaw-rate-coupled)
      local p_right = lin_right_comp * lateral_scale

      -- Integral accumulation on perpendicular-to-heading position error.
      -- position_delta is already world-space; project onto right_world.
      local lateral_pos_err = position_delta.x * right_world.x + position_delta.y * right_world.y
      -- Only integrate when the error is meaningful (not inside deadband
      -- threshold) and the correction isn't already saturated. Also skip
      -- integration at very large errors to avoid wind-up on teleport-class
      -- mismatches.
      if math.abs(lateral_pos_err) > 0.02 and math.abs(lateral_pos_err) < 8.0 then
        M.lateral_integral = M.lateral_integral + lateral_pos_err * dt
        if M.lateral_integral > LATERAL_INTEGRAL_CLAMP then
          M.lateral_integral = LATERAL_INTEGRAL_CLAMP
        elseif M.lateral_integral < -LATERAL_INTEGRAL_CLAMP then
          M.lateral_integral = -LATERAL_INTEGRAL_CLAMP
        end
      end

      -- Integral force contribution (velocity delta per tick, matching
      -- the impulse convention of apply_linear_velocity). Scale by mass
      -- so this doesn't produce more acceleration on lighter vehicles.
      local i_right = Ki_lateral * M.lateral_integral * dt * ping_scale

      -- Recompose linear_force with attenuated P + integral on right axis
      local total_right = p_right + i_right
      linear_force = vec3(
        fwd_cur.x * lin_fwd_comp + right_world.x * total_right,
        fwd_cur.y * lin_fwd_comp + right_world.y * total_right,
        linear_force.z
      )
    end

    -- Apply linear PD uniformly
    if linear_force:length() > (dt * 15) then
      kiss_vehicle.apply_linear_velocity(linear_force.x, linear_force.y, linear_force.z)
    end
    -- Apply yaw-correction force at front chassis subset
    if math.abs(force_mag) > 1.0 then
      kiss_vehicle.apply_force_at_front_chassis(lat_force_x, lat_force_y, 0)
    end

    -- No angular torque on coupled rigs. Ever. The legacy impulsive
    -- primitive is never called from this branch; heading correction is
    -- purely via the lateral force at the front chassis above, and any
    -- drift below the speed gate is accepted as a visible trade-off for
    -- never whipping the hitch.

    -- Debug state stash
    last_linear_force = linear_force
    last_position_delta = position_delta
    last_velocity_diff = velocity_difference
    last_angular_force = vec3(force_mag, 0, 0)
    last_update_skipped = false

    if M.debug then draw_debug() end
    if M.debug_log then
      debug_log(dt, linear_force, vec3(force_mag, 0, 0), position_delta,
                velocity_difference, vec3(yaw_rate_err, 0, 0),
                vec3(yaw_err, 0, 0), false)
    end
    return
  end

  -- =====================================================================
  -- NON-COUPLED PATH: full PD with legacy impulsive angular torque
  -- =====================================================================
  local angular_velocity_difference = M.target_transform.angular_velocity - local_ang_vel
  local angle_delta = M.target_transform.rotation / quat(obj:getRotation())
  local angle_delta_euler = angle_delta:toEulerYXZ()
  local angular_force = (angular_velocity_difference + angle_delta_euler * ang_force + c_ang * local_ang_vel) * dt

  -- Angular deadband: if linear deadband is active AND the angular error
  -- is also small, zero the angular force too. Prevents rotation micro-
  -- twists on stationary cargo.
  if deadband_active
    and angle_delta_euler:length() < 0.05
    and angular_velocity_difference:length() < 0.5 then
    angular_force = vec3(0, 0, 0)
  end

  -- Store debug state
  last_linear_force = linear_force
  last_position_delta = position_delta
  last_velocity_diff = velocity_difference

  local ang_skipped = angular_force:length() > 25

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

local function set_target_transform(raw, accel_clamp)
  local transform = jsonDecode(raw)
  local time_dif = clamp((transform.sent_at - M.received_transform.sent_at), 0.01, 0.1)

  -- Raw finite-difference acceleration from the velocity delta between
  -- this packet and the last. During sustained turns the raw accel
  -- vector rotates each packet (it's the instantaneous centripetal
  -- direction sampled at the packet moment), which causes the
  -- extrapolated target sphere to wobble port/starboard as the
  -- direction discretely updates per packet. Fix: low-pass filter
  -- across packets so the target extrapolation uses a smoothed
  -- acceleration vector.
  local new_raw_accel = (vec3(transform.velocity) - M.received_transform.velocity) / time_dif
  local raw_accel = new_raw_accel:length()
  -- Clamp the raw sample first (default 15 m/s² ~1.5 g). Covers
  -- cornering centripetal accel (v²/r ~5-10 m/s² in typical turns)
  -- and hard braking. The kisstuning "Max predicted accel" slider
  -- controls this.
  local clamp_val = accel_clamp or 15
  if new_raw_accel:length() > clamp_val then
    new_raw_accel = new_raw_accel:normalized() * clamp_val
  end
  -- Exponential smoothing: 70% previous smoothed value, 30% new raw.
  -- Time constant ~3 packets (~100ms at 30Hz tickrate). Damps the
  -- per-packet rotation of the accel vector during turns without
  -- being too laggy on legitimate accel changes (braking, impacts).
  M.received_transform.acceleration =
    M.received_transform.acceleration * 0.7 + new_raw_accel * 0.3
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
