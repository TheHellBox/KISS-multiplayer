-- Cluster pose sender — Phase 2.
--
-- Computes a per-cluster pose snapshot (position, rotation, linear
-- velocity, angular velocity) from live node positions and
-- velocities. This is the owner-side half of the generalized
-- front-puller: the output of compute_pose describes the rigid-body
-- motion of the cluster and is what a remote client needs in order
-- to apply velocity-matching forces.
--
-- Pure math module — obj:* access is injected via the get_pos /
-- get_vel callbacks so the whole thing is unit-testable without a
-- BeamNG runtime. The live-runtime adapter that binds to obj:*
-- lives in kiss_transforms.update().
--
-- NOTE: Phase 2 uses the degenerate single-cluster case and
-- reuses the existing VehicleUpdate transform channel for
-- networking (each vehicle has at most 1 cluster at this phase, so
-- the whole-vehicle transform IS the cluster pose). The sender
-- still runs because it's the canonical source for cluster-level
-- rotation — the receiver uses the best-fit quat directly rather
-- than trusting the vehicle's ref-node matrix, which may drift
-- away from the cluster centroid under deformation.

local M = {}

-- cluster_math is exposed as a global by BeamNG's
-- loadModulesInDirectory auto-loader. Because module load order is
-- alphabetical and cluster_math comes before cluster_sender, it's
-- usually available by the time any M.* is called. We still look
-- it up LAZILY at call time (not at module-body time) so:
--   (a) if this module loads before cluster_math we don't cache a
--       nil reference permanently, and
--   (b) tests can set _G.cluster_math after requiring this module.
local function get_cluster_math()
  return _G.cluster_math
end

-- ============================================================
-- compute_pose(cluster, masses, get_pos, get_vel)
--
--   Returns a pose table:
--     {
--       pos     = vec3,  -- mass-weighted world centroid
--       rot     = quat,  -- Horn best-fit rotation (cluster local → world)
--       lin_vel = vec3,  -- mass-weighted linear velocity
--       ang_vel = vec3,  -- angular velocity about centroid (world frame)
--       total_mass = number,
--     }
--
--   `cluster` must have .nodes and .node_offsets_local populated
--   by cluster_frames.compute_offsets at spawn time.
--
--   `masses[cid]` is the per-node mass; constant between frames.
--
--   `get_pos(cid)` returns the node's current world position (vec3).
--   `get_vel(cid)` returns the node's current world velocity (vec3).
--
--   Angular velocity is computed from angular momentum about the
--   centroid:
--     L   = Σ m_k (r_k × v_k)    where r_k = pos_k - pos_cm, v_k = vel_k - vel_cm
--     I   = Σ m_k ((r·r)I₃ − r⊗r)
--     ω   = I⁻¹ L
--
--   The 3×3 inertia tensor is symmetric positive-definite as long
--   as the cluster spans 3 dimensions. A colinear or single-point
--   cluster will make I singular; we fall back to ω = 0 in that
--   case. Callers should prefer larger clusters.
-- ============================================================
function M.compute_pose(cluster, masses, get_pos, get_vel)
  -- Mass-weighted centroid + linear velocity.
  local cx, cy, cz = 0, 0, 0
  local vx, vy, vz = 0, 0, 0
  local total = 0
  for _, cid in ipairs(cluster.nodes) do
    local m = masses[cid] or 0
    if m > 0 then
      local p = get_pos(cid)
      local v = get_vel(cid)
      cx = cx + p.x * m;  cy = cy + p.y * m;  cz = cz + p.z * m
      vx = vx + v.x * m;  vy = vy + v.y * m;  vz = vz + v.z * m
      total = total + m
    end
  end

  if total <= 0 then
    return {
      pos        = vec3(0, 0, 0),
      rot        = quat(0, 0, 0, 1),
      lin_vel    = vec3(0, 0, 0),
      ang_vel    = vec3(0, 0, 0),
      total_mass = 0,
    }
  end

  local inv_total = 1 / total
  local centroid = vec3(cx * inv_total, cy * inv_total, cz * inv_total)
  local lin_vel  = vec3(vx * inv_total, vy * inv_total, vz * inv_total)

  -- Best-fit rotation via Horn (cluster_math).
  local cm = get_cluster_math()
  local rot = cm
    and cm.best_fit_rotation(cluster, centroid, masses, get_pos)
    or quat(0, 0, 0, 1)

  -- Angular momentum + inertia tensor in world frame, computed in
  -- a single pass over nodes. L = Σ m (r × (v - v_cm)).
  local Lx, Ly, Lz = 0, 0, 0
  local Ixx, Iyy, Izz = 0, 0, 0
  local Ixy, Ixz, Iyz = 0, 0, 0
  for _, cid in ipairs(cluster.nodes) do
    local m = masses[cid] or 0
    if m > 0 then
      local p = get_pos(cid)
      local v = get_vel(cid)
      local rx = p.x - centroid.x
      local ry = p.y - centroid.y
      local rz = p.z - centroid.z
      local ux = v.x - lin_vel.x
      local uy = v.y - lin_vel.y
      local uz = v.z - lin_vel.z
      -- L += m * (r × u)
      Lx = Lx + m * (ry * uz - rz * uy)
      Ly = Ly + m * (rz * ux - rx * uz)
      Lz = Lz + m * (rx * uy - ry * ux)
      -- I += m * ((r·r) I₃ - r ⊗ r)
      local r2 = rx * rx + ry * ry + rz * rz
      Ixx = Ixx + m * (r2 - rx * rx)
      Iyy = Iyy + m * (r2 - ry * ry)
      Izz = Izz + m * (r2 - rz * rz)
      Ixy = Ixy - m * rx * ry
      Ixz = Ixz - m * rx * rz
      Iyz = Iyz - m * ry * rz
    end
  end

  -- Invert the symmetric 3×3 inertia tensor to solve I ω = L.
  -- Expanded cofactor formula (cheaper than general 3×3 inverse).
  local det = Ixx * (Iyy * Izz - Iyz * Iyz)
            - Ixy * (Ixy * Izz - Iyz * Ixz)
            + Ixz * (Ixy * Iyz - Iyy * Ixz)

  local ang_vel
  if math.abs(det) < 1e-9 then
    -- Degenerate (colinear / single-point) — no recoverable ω.
    ang_vel = vec3(0, 0, 0)
  else
    local inv_det = 1 / det
    -- Symmetric inverse: (I⁻¹)_ij = cofactor / det
    local A11 =  (Iyy * Izz - Iyz * Iyz) * inv_det
    local A12 = -(Ixy * Izz - Iyz * Ixz) * inv_det
    local A13 =  (Ixy * Iyz - Iyy * Ixz) * inv_det
    local A22 =  (Ixx * Izz - Ixz * Ixz) * inv_det
    local A23 = -(Ixx * Iyz - Ixy * Ixz) * inv_det
    local A33 =  (Ixx * Iyy - Ixy * Ixy) * inv_det
    ang_vel = vec3(
      A11 * Lx + A12 * Ly + A13 * Lz,
      A12 * Lx + A22 * Ly + A23 * Lz,
      A13 * Lx + A23 * Ly + A33 * Lz
    )
  end

  return {
    pos        = centroid,
    rot        = rot,
    lin_vel    = lin_vel,
    ang_vel    = ang_vel,
    total_mass = total,
  }
end

-- ============================================================
-- compute_all_poses(clusters, masses, get_pos, get_vel)
--   Convenience wrapper: computes pose for every cluster in the
--   list. Returns { [cluster.id] = pose }.
-- ============================================================
function M.compute_all_poses(clusters, masses, get_pos, get_vel)
  local out = {}
  for _, c in ipairs(clusters) do
    out[c.id] = M.compute_pose(c, masses, get_pos, get_vel)
  end
  return out
end

return M
