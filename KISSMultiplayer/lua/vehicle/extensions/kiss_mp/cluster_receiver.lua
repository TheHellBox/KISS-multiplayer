-- Cluster pose receiver — Phase 2.
--
-- Remote-side half of the generalized front-puller. Consumes a
-- target cluster pose (position, rotation, linear/angular velocity)
-- and applies per-node velocity-matching forces so that the
-- cluster's nodes converge toward where the owner says they should
-- be.
--
-- Force model per node (spec §4.4):
--
--   target_world_offset = rot * rest_offset_local     -- cluster local → world
--   target_pos          = centroid + target_world_offset
--   target_vel          = lin_vel + ang_vel × target_world_offset
--
--   pos_err             = target_pos - current_pos
--   target_vel         += KP_POS * pos_err            -- position-spring
--
--   required_accel      = (target_vel - current_vel) / dt
--   force               = clamp(mass * required_accel, ±MAX_FORCE_PER_NODE_N)
--
-- The position-spring term is the small PD-light nudge from
-- NodeClusterSync.md §4.4: pure velocity matching is marginally
-- stable but slowly drifts under numerical error / transient
-- impulses; the position-spring pulls residual drift out. KP_POS
-- is tuned from cluster_state.const.
--
-- Pure math module — obj:* access is injected via get_pos /
-- get_vel / apply_force callbacks so this is unit-testable
-- without a BeamNG runtime.

local M = {}

-- ============================================================
-- compute_node_force(rest_offset, target_pose, mass,
--                    current_pos, current_vel, dt, kp_pos, max_force)
--
--   Returns the force vec3 to apply to a single node so it
--   converges toward its target position/velocity as given by
--   the cluster pose. Stateless — callable from tests directly.
-- ============================================================
function M.compute_node_force(rest_offset, target_pose, mass,
                              current_pos, current_vel, dt,
                              kp_pos, max_force, convergence_gain)
  if mass <= 0 or dt <= 0 then
    return vec3(0, 0, 0)
  end

  -- Target position: centroid + rotated rest offset.
  local world_off = target_pose.rot * rest_offset
  local target_pos = target_pose.pos + world_off

  -- Target velocity: linear velocity of the CM + ω × r (rigid body).
  local target_vel = target_pose.lin_vel + target_pose.ang_vel:cross(world_off)

  -- Position-spring nudge (spec §4.4 "small KP_POS position spring").
  local pos_err = target_pos - current_pos
  target_vel = target_vel + pos_err * kp_pos

  -- Required acceleration to close the velocity gap. convergence_gain
  -- scales the correction: 1.0 closes the entire gap in one tick
  -- (stiff, fights local soft-body physics → elastic wobble), lower
  -- values spread convergence over more ticks, letting BeamNG's beam
  -- solver respond naturally. Default 1.0 for backwards compat with
  -- tests; runtime callers pass ~0.2-0.4.
  local gain = convergence_gain or 1.0
  local vel_err = target_vel - current_vel
  local force_x = mass * vel_err.x * gain / dt
  local force_y = mass * vel_err.y * gain / dt
  local force_z = mass * vel_err.z * gain / dt

  -- Per-component clamp at the max-force budget. Using per-component
  -- rather than magnitude so the clamp doesn't rotate the force
  -- direction under saturation.
  if max_force and max_force > 0 then
    if force_x >  max_force then force_x =  max_force end
    if force_x < -max_force then force_x = -max_force end
    if force_y >  max_force then force_y =  max_force end
    if force_y < -max_force then force_y = -max_force end
    if force_z >  max_force then force_z =  max_force end
    if force_z < -max_force then force_z = -max_force end
  end

  return vec3(force_x, force_y, force_z)
end

-- ============================================================
-- apply_cluster_forces(cluster, target_pose, masses, dt, const,
--                      get_pos, get_vel, apply_force)
--
--   Walks every node in the cluster and applies velocity-matching
--   force via the injected apply_force(cid, force_vec3) callback.
--   Returns diagnostic totals: (sum_force_magnitude, sum_pos_err_sq).
-- ============================================================
function M.apply_cluster_forces(cluster, target_pose, masses, dt, const,
                                get_pos, get_vel, apply_force)
  if not cluster or not target_pose then return 0, 0 end
  local kp_pos = (const and const.KP_POS) or 50.0
  local max_f  = (const and const.MAX_FORCE_PER_NODE_N) or 50000
  local gain   = (const and const.CONVERGENCE_GAIN) or 1.0

  local sum_force = 0
  local sum_pos_err_sq = 0
  for _, cid in ipairs(cluster.nodes) do
    local rest = cluster.node_offsets_local and cluster.node_offsets_local[cid]
    if rest then
      local mass = masses[cid] or 0
      local cur_pos = get_pos(cid)
      local cur_vel = get_vel(cid)
      local f = M.compute_node_force(
        rest, target_pose, mass, cur_pos, cur_vel, dt, kp_pos, max_f, gain
      )
      apply_force(cid, f)
      sum_force = sum_force + math.sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
      -- Position error for diagnostics (not used for force).
      local world_off = target_pose.rot * rest
      local target_pos = target_pose.pos + world_off
      local d = target_pos - cur_pos
      sum_pos_err_sq = sum_pos_err_sq + d:squaredLength()
    end
  end
  return sum_force, sum_pos_err_sq
end

-- ============================================================
-- target_from_transform(transform)
--
--   Adapter: the existing kiss_transforms.set_target_transform
--   stashes a received transform in M.target_transform on the
--   vehicle side. That transform has:
--     .position (vec3)  — vehicle position (world)
--     .rotation (quat)  — vehicle rotation (body → world)
--     .velocity (vec3)  — linear velocity (world)
--     .angular_velocity (vec3) — packed (pitch, roll, yaw) as
--       scalar components = ω in the owner's body frame.
--       See kiss_vehicle.lua:158-160 and kiss_transforms.lua:115.
--
--   The cluster pose we produce uses a WORLD-frame angular
--   velocity because the receiver computes `ω × r` against
--   world-frame node offsets. Rotate body → world here.
--
--   For Phase 2 single-cluster degenerate case, the whole-vehicle
--   transform IS the root cluster pose. Phase 3+ replaces this
--   with per-cluster network payloads.
-- ============================================================
function M.target_from_transform(transform)
  if not transform then return nil end
  local rot = transform.rotation or quat(0, 0, 0, 1)
  local av_body = transform.angular_velocity or vec3(0, 0, 0)
  local av_world = rot * av_body  -- body-frame ω → world-frame ω
  return {
    pos     = transform.position or vec3(0, 0, 0),
    rot     = rot,
    lin_vel = transform.velocity or vec3(0, 0, 0),
    ang_vel = av_world,
  }
end

return M
