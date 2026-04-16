-- Pure-math cluster helpers — Phase 2 groundwork.
--
-- Horn's quaternion method for best-fit rotation between two mass-
-- weighted point sets. Used by cluster_sender at every tick to
-- compute the current cluster orientation from live node positions
-- (world-frame) relative to the spawn-time rest offsets stored in
-- cluster_frames.compute_offsets (local frame).
--
-- Why Horn and not Kabsch/SVD: SVD in pure Lua is annoying.
-- Horn's method builds a 4x4 symmetric matrix whose dominant
-- eigenvector is the optimal rotation quaternion — no SVD needed.
-- For the 4x4 eigendecomposition we use Jacobi rotations (always
-- converges for symmetric matrices, robust to near-degenerate
-- eigenvalue pairs — power iteration is not).
--
-- Reference: Horn 1987, "Closed-form solution of absolute
-- orientation using unit quaternions." J. Opt. Soc. Am. A 4:629-642.

local M = {}

-- ============================================================
-- jacobi_eig_4x4(N)
--   Full eigendecomposition of a symmetric 4x4 matrix via
--   cyclic Jacobi rotations. Returns two parallel arrays:
--     eigenvalues[i]  = real eigenvalue λ_i
--     eigenvectors[i] = {e1, e2, e3, e4} unit eigenvector
--   Input N must be symmetric; only the upper triangle is read.
-- ============================================================
local function jacobi_eig_4x4(N)
  -- Work on a mutable copy.
  local a = {}
  for i = 1, 4 do
    a[i] = {}
    for j = 1, 4 do a[i][j] = N[i][j] end
  end
  -- Eigenvector accumulator (identity initially); columns = eigvecs.
  local V = {
    {1, 0, 0, 0},
    {0, 1, 0, 0},
    {0, 0, 1, 0},
    {0, 0, 0, 1},
  }

  for sweep = 1, 50 do
    -- Find the largest off-diagonal element (by absolute value).
    local p, q, max_abs = 1, 2, 0
    for i = 1, 3 do
      for j = i + 1, 4 do
        local v = math.abs(a[i][j])
        if v > max_abs then
          max_abs = v
          p, q = i, j
        end
      end
    end
    if max_abs < 1e-14 then break end

    -- Compute Jacobi rotation that zeros a[p][q].
    local app = a[p][p]
    local aqq = a[q][q]
    local apq = a[p][q]
    local theta = (aqq - app) / (2 * apq)
    local t
    if theta >= 0 then
      t = 1 / (theta + math.sqrt(1 + theta * theta))
    else
      t = 1 / (theta - math.sqrt(1 + theta * theta))
    end
    local c = 1 / math.sqrt(1 + t * t)
    local s = t * c

    -- Update diagonal + zero the target off-diagonal.
    a[p][p] = app - t * apq
    a[q][q] = aqq + t * apq
    a[p][q] = 0
    a[q][p] = 0

    -- Rotate the other rows/columns.
    for i = 1, 4 do
      if i ~= p and i ~= q then
        local aip = a[i][p]
        local aiq = a[i][q]
        local new_ip = c * aip - s * aiq
        local new_iq = s * aip + c * aiq
        a[i][p] = new_ip
        a[p][i] = new_ip
        a[i][q] = new_iq
        a[q][i] = new_iq
      end
    end

    -- Accumulate the rotation into V.
    for i = 1, 4 do
      local vip = V[i][p]
      local viq = V[i][q]
      V[i][p] = c * vip - s * viq
      V[i][q] = s * vip + c * viq
    end
  end

  local eigenvalues = {a[1][1], a[2][2], a[3][3], a[4][4]}
  local eigenvectors = {}
  for j = 1, 4 do
    eigenvectors[j] = {V[1][j], V[2][j], V[3][j], V[4][j]}
  end
  return eigenvalues, eigenvectors
end

-- Expose for tests.
M._jacobi_eig_4x4 = jacobi_eig_4x4

-- ============================================================
-- compute_centroid_world(cluster, masses, get_world_pos)
--   Returns the mass-weighted centroid of the cluster's live node
--   positions in world space. `get_world_pos(cid)` is injected so
--   tests can supply deterministic positions without obj:*.
-- ============================================================
function M.compute_centroid_world(cluster, masses, get_world_pos)
  local cx, cy, cz, total = 0, 0, 0, 0
  for _, cid in ipairs(cluster.nodes) do
    local m = masses[cid] or 0
    if m > 0 then
      local p = get_world_pos(cid)
      cx = cx + p.x * m
      cy = cy + p.y * m
      cz = cz + p.z * m
      total = total + m
    end
  end
  if total <= 0 then return vec3(0, 0, 0), 0 end
  return vec3(cx / total, cy / total, cz / total), total
end

-- ============================================================
-- best_fit_rotation(cluster, centroid_world, masses, get_world_pos)
--
--   Returns a unit quat that rotates the cluster's rest offsets
--   (stored in cluster.node_offsets_local, cluster local frame)
--   to best match the observed world-frame offsets from
--   centroid_world. Mass-weighted least squares.
--
--   Degenerate cases:
--     - zero total mass or empty cluster → returns identity quat
--     - colinear / single-point cluster → returns identity quat
--       (rotation under-determined; caller should fall back to
--       the previous frame's orientation).
-- ============================================================
function M.best_fit_rotation(cluster, centroid_world, masses, get_world_pos)
  -- Build the 3x3 cross-covariance M_ij = Σ m_k * p_k[i] * q_k[j],
  -- where p_k is the rest offset (local) and q_k is the observed
  -- offset (world - centroid_world).
  local Sxx, Sxy, Sxz = 0, 0, 0
  local Syx, Syy, Syz = 0, 0, 0
  local Szx, Szy, Szz = 0, 0, 0
  local total = 0

  for _, cid in ipairs(cluster.nodes) do
    local m = masses[cid] or 0
    local p = cluster.node_offsets_local and cluster.node_offsets_local[cid]
    if m > 0 and p then
      local q = get_world_pos(cid) - centroid_world
      Sxx = Sxx + m * p.x * q.x
      Sxy = Sxy + m * p.x * q.y
      Sxz = Sxz + m * p.x * q.z
      Syx = Syx + m * p.y * q.x
      Syy = Syy + m * p.y * q.y
      Syz = Syz + m * p.y * q.z
      Szx = Szx + m * p.z * q.x
      Szy = Szy + m * p.z * q.y
      Szz = Szz + m * p.z * q.z
      total = total + m
    end
  end

  if total <= 0 then return quat(0, 0, 0, 1) end

  -- Horn's symmetric 4x4 matrix N. Indexed as N[w,x,y,z].
  -- Rows/cols are [w, x, y, z]; we'll extract (x,y,z,w) at the end.
  local N11 =  Sxx + Syy + Szz
  local N22 =  Sxx - Syy - Szz
  local N33 = -Sxx + Syy - Szz
  local N44 = -Sxx - Syy + Szz
  local N12 =  Syz - Szy
  local N13 =  Szx - Sxz
  local N14 =  Sxy - Syx
  local N23 =  Sxy + Syx
  local N24 =  Szx + Sxz
  local N34 =  Syz + Szy

  local N = {
    {N11, N12, N13, N14},
    {N12, N22, N23, N24},
    {N13, N23, N33, N34},
    {N14, N24, N34, N44},
  }

  -- Solve the 4x4 symmetric eigenvalue problem. Horn tells us
  -- the optimal rotation quaternion is the eigenvector with the
  -- LARGEST eigenvalue (not the largest absolute value — the
  -- smallest eigenvalue can be more negative but isn't the
  -- solution).
  local evals, evecs = jacobi_eig_4x4(N)
  local best_idx = 1
  for i = 2, 4 do
    if evals[i] > evals[best_idx] then best_idx = i end
  end
  local ev = evecs[best_idx]

  -- Horn's eigenvector order is (w, x, y, z). Our quat constructor
  -- takes (x, y, z, w). Canonicalize the sign so w >= 0 (otherwise
  -- both q and -q are valid and the sign flip is confusing in tests).
  local qw, qx, qy, qz = ev[1], ev[2], ev[3], ev[4]
  if qw < 0 then
    qw, qx, qy, qz = -qw, -qx, -qy, -qz
  end
  return quat(qx, qy, qz, qw)
end

return M
