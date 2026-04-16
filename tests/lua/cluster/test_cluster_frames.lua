-- TDD tests for cluster frame construction:
--   * mass-weighted centroid
--   * per-node local offsets
--   * inertia tensor (principal-axis orientation)
--
-- These functions live in cluster_frames.lua (pure math, no BeamNG
-- deps). The wrapper that reads obj:getNodeMass / obj:getNodePosition
-- lives separately and is not unit-tested here.

local T = {}

local frames = require("cluster_frames")

local function assert_near(a, e, tol, label)
  tol = tol or 1e-6
  if math.abs(a - e) > tol then
    error(string.format("%s: expected %.6f, got %.6f", label or "value", e, a))
  end
end

local function assert_vec_near(a, e, tol, label)
  tol = tol or 1e-6
  label = label or "vec"
  assert_near(a.x, e.x, tol, label .. ".x")
  assert_near(a.y, e.y, tol, label .. ".y")
  assert_near(a.z, e.z, tol, label .. ".z")
end

-- ============================================================
-- compute_centroid(nodes_positions, nodes_masses)
--   nodes_positions: table cid -> vec3
--   nodes_masses:    table cid -> number
-- Returns: (centroid_vec3, total_mass)
-- ============================================================

function T.test_centroid_single_node()
  local positions = { [1] = vec3(5, 3, 2) }
  local masses    = { [1] = 10 }
  local centroid, total_mass = frames.compute_centroid({1}, positions, masses)
  assert_vec_near(centroid, vec3(5, 3, 2), nil, "centroid")
  assert_near(total_mass, 10, nil, "total_mass")
end

function T.test_centroid_equal_mass_two_nodes()
  local positions = {
    [1] = vec3(0, 0, 0),
    [2] = vec3(4, 0, 0),
  }
  local masses = { [1] = 5, [2] = 5 }
  local centroid, total_mass = frames.compute_centroid({1, 2}, positions, masses)
  assert_vec_near(centroid, vec3(2, 0, 0), nil, "midpoint")
  assert_near(total_mass, 10)
end

function T.test_centroid_mass_weighted()
  -- Heavy mass at (10,0,0), light mass at (0,0,0) — centroid biased
  -- toward heavy side.
  local positions = {
    [1] = vec3(0, 0, 0),
    [2] = vec3(10, 0, 0),
  }
  local masses = { [1] = 1, [2] = 9 }
  local centroid, total_mass = frames.compute_centroid({1, 2}, positions, masses)
  assert_vec_near(centroid, vec3(9, 0, 0), 1e-9, "weighted")
  assert_near(total_mass, 10)
end

function T.test_centroid_three_dimensions()
  local positions = {
    [1] = vec3(1, 0, 0),
    [2] = vec3(0, 2, 0),
    [3] = vec3(0, 0, 3),
  }
  local masses = { [1] = 1, [2] = 1, [3] = 1 }
  local centroid, _ = frames.compute_centroid({1, 2, 3}, positions, masses)
  assert_vec_near(centroid, vec3(1/3, 2/3, 1), 1e-9, "3d centroid")
end

-- ============================================================
-- compute_offsets(cluster_nodes, positions, centroid)
--   Returns: table cid -> vec3 (each node's offset from centroid)
-- ============================================================

function T.test_offsets_are_relative_to_centroid()
  local positions = {
    [1] = vec3(0, 0, 0),
    [2] = vec3(4, 0, 0),
  }
  local centroid = vec3(2, 0, 0)
  local offsets = frames.compute_offsets({1, 2}, positions, centroid)
  assert_vec_near(offsets[1], vec3(-2, 0, 0), nil, "offset 1")
  assert_vec_near(offsets[2], vec3(2, 0, 0), nil, "offset 2")
end

function T.test_offsets_sum_to_zero_when_mass_weighted()
  -- When the centroid is the mass-weighted average, the sum of
  -- offsets weighted by mass is zero. (Verified by recomputing
  -- centroid from offsets.)
  local positions = {
    [1] = vec3(0, 0, 0),
    [2] = vec3(6, 0, 0),
    [3] = vec3(3, 4, 0),
  }
  local masses = { [1] = 1, [2] = 2, [3] = 3 }
  local centroid, total = frames.compute_centroid({1, 2, 3}, positions, masses)
  local offsets = frames.compute_offsets({1, 2, 3}, positions, centroid)
  -- Sum mass * offset should be ~0
  local sum_x, sum_y, sum_z = 0, 0, 0
  for cid, off in pairs(offsets) do
    sum_x = sum_x + masses[cid] * off.x
    sum_y = sum_y + masses[cid] * off.y
    sum_z = sum_z + masses[cid] * off.z
  end
  assert_near(sum_x, 0, 1e-9, "weighted sum x")
  assert_near(sum_y, 0, 1e-9, "weighted sum y")
  assert_near(sum_z, 0, 1e-9, "weighted sum z")
end

-- ============================================================
-- compute_inertia_tensor(cluster_nodes, offsets, masses)
--   Returns: 3x3 inertia tensor about the centroid (mat3)
-- ============================================================

function T.test_inertia_single_mass_at_unit_x_distance()
  -- Single point mass m=1 at position (1, 0, 0).
  -- Inertia about origin:
  --   Ixx = m*(y² + z²) = 0
  --   Iyy = m*(x² + z²) = 1
  --   Izz = m*(x² + y²) = 1
  --   Ixy = -m*x*y = 0, etc.
  local offsets = { [1] = vec3(1, 0, 0) }
  local masses = { [1] = 1 }
  local I = frames.compute_inertia_tensor({1}, offsets, masses)
  assert_near(I:get(1, 1), 0, 1e-9, "Ixx")
  assert_near(I:get(2, 2), 1, 1e-9, "Iyy")
  assert_near(I:get(3, 3), 1, 1e-9, "Izz")
  assert_near(I:get(1, 2), 0, 1e-9, "Ixy")
  assert_near(I:get(1, 3), 0, 1e-9, "Ixz")
  assert_near(I:get(2, 3), 0, 1e-9, "Iyz")
end

function T.test_inertia_symmetric()
  -- Inertia tensor must be symmetric: I_ij = I_ji
  local offsets = {
    [1] = vec3(1, 2, 3),
    [2] = vec3(-2, 1, 0),
    [3] = vec3(0, -3, 2),
  }
  local masses = { [1] = 2, [2] = 3, [3] = 1 }
  local I = frames.compute_inertia_tensor({1, 2, 3}, offsets, masses)
  assert_near(I:get(1, 2), I:get(2, 1), 1e-9, "Ixy == Iyx")
  assert_near(I:get(1, 3), I:get(3, 1), 1e-9, "Ixz == Izx")
  assert_near(I:get(2, 3), I:get(3, 2), 1e-9, "Iyz == Izy")
end

function T.test_inertia_diagonal_for_axis_aligned_mass()
  -- Two equal point masses along the x-axis, centered at origin.
  -- The cross terms should be zero (axis-aligned).
  local offsets = {
    [1] = vec3(-2, 0, 0),
    [2] = vec3(2, 0, 0),
  }
  local masses = { [1] = 1, [2] = 1 }
  local I = frames.compute_inertia_tensor({1, 2}, offsets, masses)
  assert_near(I:get(1, 2), 0, 1e-9, "Ixy")
  assert_near(I:get(1, 3), 0, 1e-9, "Ixz")
  assert_near(I:get(2, 3), 0, 1e-9, "Iyz")
  -- Principal values:
  --   Ixx = Σm*(y² + z²) = 0
  --   Iyy = Σm*(x² + z²) = 8
  --   Izz = Σm*(x² + y²) = 8
  assert_near(I:get(1, 1), 0, 1e-9, "Ixx")
  assert_near(I:get(2, 2), 8, 1e-9, "Iyy")
  assert_near(I:get(3, 3), 8, 1e-9, "Izz")
end

function T.test_inertia_additivity()
  -- I(cluster) = sum of per-node contributions. Splitting a cluster
  -- into two halves and summing their tensors should equal the
  -- whole.
  local offsets = {
    [1] = vec3(1, 0, 0),
    [2] = vec3(0, 1, 0),
    [3] = vec3(0, 0, 1),
    [4] = vec3(-1, -1, -1),
  }
  local masses = { [1] = 1, [2] = 1, [3] = 1, [4] = 1 }
  local I_all = frames.compute_inertia_tensor({1, 2, 3, 4}, offsets, masses)
  local I_ab  = frames.compute_inertia_tensor({1, 2}, offsets, masses)
  local I_cd  = frames.compute_inertia_tensor({3, 4}, offsets, masses)
  for r = 1, 3 do
    for c = 1, 3 do
      assert_near(
        I_all:get(r, c),
        I_ab:get(r, c) + I_cd:get(r, c),
        1e-9,
        string.format("I[%d][%d] additivity", r, c)
      )
    end
  end
end

return T
