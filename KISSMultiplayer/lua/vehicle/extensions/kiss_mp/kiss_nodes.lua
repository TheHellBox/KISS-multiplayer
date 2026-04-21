-- KissMP cluster-node sync: Layer 2 of the layered-sync model.
--
-- Layer 1 (cluster Transform: pos, rot, linvel, angvel) is carried on every
-- VehicleUpdate and handles the vehicle's overall trajectory. This module
-- carries Layer 2 — per-node DEVIATION from the rigid motion predicted by
-- Layer 1. Chassis nodes at rest deviate zero and are omitted from the packet
-- entirely; wheels, suspension, deformed panels contribute deviations that
-- can't be reconstructed from Layer 1 alone.
--
-- Receiver reconstructs each node's absolute target as `rigid_prediction +
-- deviation`, then applies a single blended impulse per node. No
-- setNodePosition anywhere — every correction goes through applyForceVector,
-- so the solver never sees two conflicting velocity signals.

local M = {}

-- Tuning (live-editable from GE via M.set_tuning; imgui Tuning tab writes here).
-- Defaults chosen so a standalone vehicle lua works with no GE wiring.
local POSITION_SCALE = 1000          -- i16 units per metre   (mm precision, ±32.767 m range)
local VELOCITY_SCALE = 100           -- i16 units per m/s     (cm/s precision, ±327.67 m/s range)
local POSITION_EPSILON = 1           -- sender-side quantized-unit threshold for position entries
local VELOCITY_EPSILON = 1           -- sender-side quantized-unit threshold for velocity entries
local POSITION_PULL_GAIN = 30        -- spring gain: velocity correction per metre of position error
-- Receiver-side gates for vehicle-and-prop agnosticism. Gate 1 skips impulses
-- entirely when a node is within tolerance of target (stationary props have
-- every node in this regime → no impulses → no ground-contact fight). Gate 2
-- clamps per-tick Δv magnitude so no single bad packet can detonate the jbeam.
local POSITION_DEADBAND = 0.01       -- metres: skip if |Δp| below this
local VELOCITY_DEADBAND = 0.1        -- m/s: skip if |Δv| below this
local MAX_DELTA_V_PER_TICK = 10.0    -- m/s: clamp per-tick velocity change to this ceiling

local I16_MIN = -32768
local I16_MAX = 32767

-- Per-cid body-frame rest position, populated lazily on first capture/apply.
-- Prefer v.data.nodes[cid].pos (authored jbeam static — identical on both clients).
-- Fall back to inverse_rot * obj:getNodePosition(cid) at load time if .pos isn't
-- available, matching the kiss_vehicle.lua:28 pattern.
local rest_body_by_cid = nil

local function build_rest_cache()
  if rest_body_by_cid then return end
  rest_body_by_cid = {}
  local inverse_rot = quat(obj:getRotation()):inversed()
  for _, node in pairs(v.data.nodes) do
    local cid = node.cid
    local p = node.pos
    if p and (p.x ~= nil or p[1] ~= nil) then
      -- Authored jbeam rest in vehicle body frame.
      rest_body_by_cid[cid] = vec3(
        p.x or p[1],
        p.y or p[2],
        p.z or p[3]
      )
    else
      -- Fallback: runtime node position at extension-load, rotated into body frame.
      rest_body_by_cid[cid] = inverse_rot * obj:getNodePosition(cid)
    end
  end
end

local function quantize(val, scale)
  local q = math.floor(val * scale + 0.5)
  if q > I16_MAX then return I16_MAX end
  if q < I16_MIN then return I16_MIN end
  return q
end

local function abs_i(x) return x < 0 and -x or x end

--- Capture Layer 2 deviations on the authority side.
--- Returns two maps keyed by stringified CID (so jsonEncode produces JSON
--- objects matching the Rust HashMap, unambiguously).
---   positions[cid] = body-frame position deviation from rest, quantized
---   velocities[cid] = world-frame velocity deviation from rigid motion, quantized
--- Entries whose magnitude falls below the epsilon threshold are omitted.
local function capture_nodes()
  build_rest_cache()
  local positions = {}
  local velocities = {}

  local inverse_rot = quat(obj:getRotation()):inversed()
  local cluster_linvel = vec3(obj:getVelocity())
  -- Body-frame angular velocity (pitch/roll/yaw) → world frame via current rotation
  local cluster_angvel = vec3(
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity(),
    obj:getYawAngularVelocity()
  ):rotated(quat(obj:getRotation()))

  for _, node in pairs(v.data.nodes) do
    local cid = node.cid
    local key = tostring(cid)
    local rest_body = rest_body_by_cid[cid]

    -- Position deviation in body frame = (current body pos) - (rest body pos)
    local body_pos = inverse_rot * obj:getNodePosition(cid)
    local qx = quantize(body_pos.x - rest_body.x, POSITION_SCALE)
    local qy = quantize(body_pos.y - rest_body.y, POSITION_SCALE)
    local qz = quantize(body_pos.z - rest_body.z, POSITION_SCALE)
    if abs_i(qx) > POSITION_EPSILON or abs_i(qy) > POSITION_EPSILON or abs_i(qz) > POSITION_EPSILON then
      positions[key] = { qx, qy, qz }
    end

    -- Velocity deviation in world frame = (actual node vel) - (rigid prediction)
    -- rigid_vel = v_cluster + ω_cluster × r, where r is node offset from cluster ref
    local world_offset = obj:getNodePosition(cid)  -- already world-oriented offset from ref
    local rigid_vel = cluster_linvel + cluster_angvel:cross(world_offset)
    local node_vel = obj:getNodeVelocityVector(cid)
    local vqx = quantize(node_vel.x - rigid_vel.x, VELOCITY_SCALE)
    local vqy = quantize(node_vel.y - rigid_vel.y, VELOCITY_SCALE)
    local vqz = quantize(node_vel.z - rigid_vel.z, VELOCITY_SCALE)
    if abs_i(vqx) > VELOCITY_EPSILON or abs_i(vqy) > VELOCITY_EPSILON or abs_i(vqz) > VELOCITY_EPSILON then
      velocities[key] = { vqx, vqy, vqz }
    end
  end

  return positions, velocities
end

-- Per-vehicle flag: until the first packet is applied (or after a
-- severe-desync detection), we must hard-set node positions rather than try
-- to impulse-correct them. Blended correction with huge deltas generates
-- billion-Newton forces and disintegrates the jbeam in a single tick.
M.initialized = false

-- If any touched node has |Δp| > this threshold, re-enter initial-sync mode.
-- Self-heals from authority teleports / long disconnects without operator
-- intervention.
local LARGE_DELTA_THRESHOLD = 2.0  -- metres
local LARGE_DELTA_SQ = LARGE_DELTA_THRESHOLD * LARGE_DELTA_THRESHOLD

-- Called from kiss_transforms.onReset — a local vehicle:reset() snaps nodes
-- back to rest and invalidates any in-flight corrections, so the next packet
-- should hard-set rather than blended-correct.
local function onReset()
  M.initialized = false
end

--- Apply Layer 1 + Layer 2 on the receiver.
--- Called from kiss_transforms.set_target_transform with the full cluster
--- transform sampled at the same sender tick as the deviations.
--- cluster_rot is a quat, cluster_linvel and cluster_angvel are world-frame vec3.
local function apply_nodes(cluster_rot, cluster_linvel, cluster_angvel, positions, velocities)
  build_rest_cache()

  -- Union of cids mentioned in either map. Nodes absent from both are at
  -- rigid prediction by definition; leave them to local physics.
  local touched = {}
  if positions then
    for k in pairs(positions) do touched[k] = true end
  end
  if velocities then
    for k in pairs(velocities) do touched[k] = true end
  end

  -- First pass: compute p_target per touched node and detect large deltas.
  -- If any touched node's Δp exceeds threshold, we force initial-sync mode.
  local targets = {}
  local must_init = not M.initialized
  for key in pairs(touched) do
    local cid = tonumber(key)
    local rest_body = cid and rest_body_by_cid[cid]
    if cid and rest_body then
      local pos_dev = positions and positions[key]
      local tbx, tby, tbz = rest_body.x, rest_body.y, rest_body.z
      if pos_dev and #pos_dev >= 3 then
        tbx = tbx + pos_dev[1] / POSITION_SCALE
        tby = tby + pos_dev[2] / POSITION_SCALE
        tbz = tbz + pos_dev[3] / POSITION_SCALE
      end
      local p_target = cluster_rot * vec3(tbx, tby, tbz)
      targets[key] = { cid = cid, p_target = p_target }

      if not must_init then
        local p_current = obj:getNodePosition(cid)
        local dx = p_target.x - p_current.x
        local dy = p_target.y - p_current.y
        local dz = p_target.z - p_current.z
        if (dx * dx + dy * dy + dz * dz) > LARGE_DELTA_SQ then
          must_init = true
        end
      end
    end
  end

  -- Initial-sync mode: hard-set positions only. No applyForceVector on this
  -- tick so the solver doesn't see two inconsistent velocity signals.
  -- Integrator derives an initial velocity from the position change; next
  -- packet's blended correction stabilizes it.
  if must_init then
    for _, t in pairs(targets) do
      obj:setNodePosition(t.cid, float3(t.p_target.x, t.p_target.y, t.p_target.z))
    end
    M.initialized = true
    return
  end

  -- Steady-state blended correction. Deltas are small; impulse is physically
  -- reasonable; no setNodePosition this tick.
  local physics_fps = obj:getPhysicsFPS()
  for key, t in pairs(targets) do
    local cid = t.cid
    local p_target = t.p_target
    local p_current = obj:getNodePosition(cid)

    -- Lever-arm convention: use node's CURRENT position for rigid_vel,
    -- matching the sender's convention (sender used obj:getNodePosition(cid)
    -- at capture time, not the reconstructed target). Using p_target here
    -- introduces a bias of ω × Δp that shows up as visible position bob.
    local rigid_vel = cluster_linvel + cluster_angvel:cross(p_current)
    local vel_dev = velocities and velocities[key]
    local v_target_x = rigid_vel.x
    local v_target_y = rigid_vel.y
    local v_target_z = rigid_vel.z
    if vel_dev and #vel_dev >= 3 then
      v_target_x = v_target_x + vel_dev[1] / VELOCITY_SCALE
      v_target_y = v_target_y + vel_dev[2] / VELOCITY_SCALE
      v_target_z = v_target_z + vel_dev[3] / VELOCITY_SCALE
    end

    local v_current = obj:getNodeVelocityVector(cid)
    local m = obj:getNodeMass(cid)
    local factor = m * physics_fps

    -- v_desired = v_target + k_pos · (p_target - p_current)
    -- F        = m · FPS · (v_desired - v_current)
    local vd_x = v_target_x + POSITION_PULL_GAIN * (p_target.x - p_current.x)
    local vd_y = v_target_y + POSITION_PULL_GAIN * (p_target.y - p_current.y)
    local vd_z = v_target_z + POSITION_PULL_GAIN * (p_target.z - p_current.z)

    local dv_x = vd_x - v_current.x
    local dv_y = vd_y - v_current.y
    local dv_z = vd_z - v_current.z

    -- Gate 1: per-node apply gating. Skip impulse entirely if both position
    -- and velocity are within dead-band tolerance of target. This is what
    -- makes the sync vehicle-and-prop agnostic — stationary rigid props have
    -- every node in this regime and receive no impulses, so they don't fight
    -- ground contact / float off. Spinning wheels / deforming panels have Δv
    -- outside the band and get corrected normally.
    local dp_x = p_target.x - p_current.x
    local dp_y = p_target.y - p_current.y
    local dp_z = p_target.z - p_current.z
    local dp_sq = dp_x * dp_x + dp_y * dp_y + dp_z * dp_z
    local dv_sq = dv_x * dv_x + dv_y * dv_y + dv_z * dv_z
    if dp_sq < POSITION_DEADBAND * POSITION_DEADBAND
        and dv_sq < VELOCITY_DEADBAND * VELOCITY_DEADBAND then
      -- within tolerance — no impulse this tick
    else
      -- Gate 2: structural force cap. Clamp per-tick Δv magnitude so no
      -- single bad packet or pathological reconstruction can produce a
      -- jbeam-detonating impulse.
      if dv_sq > MAX_DELTA_V_PER_TICK * MAX_DELTA_V_PER_TICK then
        local scale = MAX_DELTA_V_PER_TICK / math.sqrt(dv_sq)
        dv_x = dv_x * scale
        dv_y = dv_y * scale
        dv_z = dv_z * scale
      end

      obj:applyForceVector(
        cid,
        float3(dv_x * factor, dv_y * factor, dv_z * factor)
      )
    end
  end
end

--- Live-tuning setter called from GE when imgui sliders change.
--- Any nil arg leaves that value unchanged.
local function set_tuning(position_scale, velocity_scale, pos_eps, vel_eps, pull_gain,
                          pos_deadband, vel_deadband, max_dv)
  if position_scale then POSITION_SCALE = position_scale end
  if velocity_scale then VELOCITY_SCALE = velocity_scale end
  if pos_eps then POSITION_EPSILON = pos_eps end
  if vel_eps then VELOCITY_EPSILON = vel_eps end
  if pull_gain then POSITION_PULL_GAIN = pull_gain end
  if pos_deadband then POSITION_DEADBAND = pos_deadband end
  if vel_deadband then VELOCITY_DEADBAND = vel_deadband end
  if max_dv then MAX_DELTA_V_PER_TICK = max_dv end
end

M.capture_nodes = capture_nodes
M.apply_nodes = apply_nodes
M.set_tuning = set_tuning
M.onReset = onReset

return M
