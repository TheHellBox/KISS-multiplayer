-- Tests for cluster_math.lua — Horn's best-fit rotation.
--
-- Strategy: construct a cluster with a handful of rest offsets,
-- apply a known quat to produce "world-frame" offsets, run
-- best_fit_rotation, verify the recovered quat either equals
-- the applied quat or rotates a test vector to the same result
-- (sign-ambiguous quats equivalent under ±1).

local cluster_math = require("cluster_math")

local T = {}

-- ============================================================
-- Helpers
-- ============================================================

-- Build a cluster with given node offsets keyed by cid. Returns
-- a table shaped like cluster_spawn's output (just the fields
-- best_fit_rotation reads).
local function make_cluster(offsets)
  local cluster = {nodes = {}, node_offsets_local = {}}
  for cid, off in pairs(offsets) do
    table.insert(cluster.nodes, cid)
    cluster.node_offsets_local[cid] = off
  end
  table.sort(cluster.nodes)
  return cluster
end

-- Uniform-mass dict for a cluster (1 kg per node).
local function unit_masses(cluster)
  local m = {}
  for _, cid in ipairs(cluster.nodes) do m[cid] = 1.0 end
  return m
end

-- Build world-positions dict by applying rotation+translation to
-- each rest offset. Returns a closure get_world_pos(cid) matching
-- best_fit_rotation's expected signature.
local function make_world_positions(cluster, q, translation)
  translation = translation or vec3(0, 0, 0)
  local positions = {}
  for _, cid in ipairs(cluster.nodes) do
    local rest = cluster.node_offsets_local[cid]
    positions[cid] = (q * rest) + translation
  end
  return function(cid) return positions[cid] end
end

-- Check that two quats represent the same rotation, i.e.
-- q1 ≈ ±q2. Tolerance on the component-wise difference.
local function quats_equivalent(q1, q2, tol)
  tol = tol or 1e-4
  local d1 = math.abs(q1.x - q2.x) + math.abs(q1.y - q2.y)
             + math.abs(q1.z - q2.z) + math.abs(q1.w - q2.w)
  local d2 = math.abs(q1.x + q2.x) + math.abs(q1.y + q2.y)
             + math.abs(q1.z + q2.z) + math.abs(q1.w + q2.w)
  return math.min(d1, d2) < tol
end

-- A well-spread reference cluster: 8 corners of a unit cube.
local function cube_cluster()
  return make_cluster({
    [1] = vec3(-1, -1, -1),
    [2] = vec3( 1, -1, -1),
    [3] = vec3( 1,  1, -1),
    [4] = vec3(-1,  1, -1),
    [5] = vec3(-1, -1,  1),
    [6] = vec3( 1, -1,  1),
    [7] = vec3( 1,  1,  1),
    [8] = vec3(-1,  1,  1),
  })
end

-- ============================================================
-- Tests
-- ============================================================

function T.test_identity_rotation_recovers_identity()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local identity = quat(0, 0, 0, 1)
  local get_pos = make_world_positions(cluster, identity)
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  assert(quats_equivalent(result, identity),
         "expected identity, got " .. tostring(result))
end

function T.test_small_yaw_recovers()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local q = quatFromAxisAngle(vec3(0, 0, 1), math.rad(15))
  local get_pos = make_world_positions(cluster, q)
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  assert(quats_equivalent(result, q),
         "expected " .. tostring(q) .. ", got " .. tostring(result))
end

function T.test_90_degree_yaw()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local q = quatFromAxisAngle(vec3(0, 0, 1), math.rad(90))
  local get_pos = make_world_positions(cluster, q)
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  assert(quats_equivalent(result, q),
         "expected " .. tostring(q) .. ", got " .. tostring(result))
end

function T.test_rotation_plus_translation()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local q = quatFromAxisAngle(vec3(1, 0, 0), math.rad(30))
  local t = vec3(5, -3, 2)
  local get_pos = make_world_positions(cluster, q, t)
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  -- centroid should equal translation since rest offsets sum to 0
  assert(math.abs(centroid.x - t.x) < 1e-9, "centroid x")
  assert(math.abs(centroid.y - t.y) < 1e-9, "centroid y")
  assert(math.abs(centroid.z - t.z) < 1e-9, "centroid z")
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  assert(quats_equivalent(result, q),
         "expected " .. tostring(q) .. ", got " .. tostring(result))
end

function T.test_arbitrary_axis_rotation()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local axis = vec3(0.3, 0.5, 0.8):normalized()
  local q = quatFromAxisAngle(axis, math.rad(47))
  local get_pos = make_world_positions(cluster, q)
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  assert(quats_equivalent(result, q, 1e-3),
         "expected " .. tostring(q) .. ", got " .. tostring(result))
end

function T.test_near_180_rotation()
  -- Near-180 is the pathological case for unit quaternions: w→0
  -- and the power iteration starting vector (1,1,1,1)/2 must stay
  -- non-orthogonal to the dominant eigenvector.
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local q = quatFromAxisAngle(vec3(0, 0, 1), math.rad(179))
  local get_pos = make_world_positions(cluster, q)
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  -- Under near-180, rotate a test vector and verify both take it
  -- to the same place (more robust than component-wise comparison).
  local test_vec = vec3(1, 0.3, 0.7)
  local expected = q * test_vec
  local actual = result * test_vec
  local err = (expected - actual):length()
  assert(err < 1e-3, string.format(
    "near-180 mismatch: expected %s, got %s, err=%.6f",
    tostring(expected), tostring(actual), err))
end

function T.test_mass_weighting()
  -- Symmetric offsets so mean stays zero under asymmetric masses.
  -- The heavy pair [1][2] dominates the fit even with small noise
  -- injected on the light pair. Verifies that best_fit_rotation
  -- actually reads the mass dict.
  local cluster = make_cluster({
    [1] = vec3( 1, 0, 0),
    [2] = vec3(-1, 0, 0),
    [3] = vec3( 0, 1, 0),
    [4] = vec3( 0,-1, 0),
  })
  local masses = {[1] = 1000, [2] = 1000, [3] = 1, [4] = 1}
  local q = quatFromAxisAngle(vec3(0, 0, 1), math.rad(45))
  -- Clean rotation on heavy pair; perturb light pair to create a
  -- conflict. Without mass weighting the result averages both
  -- signals; with mass weighting the heavy pair wins.
  local clean = make_world_positions(cluster, q)
  local noisy_pos = {
    [1] = clean(1),
    [2] = clean(2),
    [3] = clean(3) + vec3(0.5, 0, 0),  -- large noise on light
    [4] = clean(4) + vec3(-0.5, 0, 0),
  }
  local get_pos = function(cid) return noisy_pos[cid] end
  local centroid, _ = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  local result = cluster_math.best_fit_rotation(cluster, centroid, masses, get_pos)
  -- Heavy nodes should fit nearly perfectly.
  local predicted1 = result * cluster.node_offsets_local[1] + centroid
  local err1 = (noisy_pos[1] - predicted1):length()
  assert(err1 < 5e-3, string.format("heavy-node fit error: %.6f", err1))
  -- And the recovered quat should be close to q (not averaged
  -- with the noise direction).
  assert(quats_equivalent(result, q, 5e-3),
         "expected " .. tostring(q) .. ", got " .. tostring(result))
end

function T.test_centroid_world_weighted()
  local cluster = make_cluster({
    [1] = vec3(0, 0, 0),
    [2] = vec3(10, 0, 0),
  })
  local masses = {[1] = 3, [2] = 1}
  local get_pos = function(cid) return cluster.node_offsets_local[cid] end
  local centroid, total = cluster_math.compute_centroid_world(cluster, masses, get_pos)
  assert(math.abs(total - 4) < 1e-9, "total mass")
  -- Weighted mean: (3*0 + 1*10) / 4 = 2.5
  assert(math.abs(centroid.x - 2.5) < 1e-9, "x centroid")
end

function T.test_zero_mass_returns_identity()
  local cluster = cube_cluster()
  local masses = {}
  for _, cid in ipairs(cluster.nodes) do masses[cid] = 0 end
  local get_pos = function() return vec3(0, 0, 0) end
  local result = cluster_math.best_fit_rotation(cluster, vec3(0, 0, 0), masses, get_pos)
  assert(quats_equivalent(result, quat(0, 0, 0, 1)),
         "expected identity, got " .. tostring(result))
end

return T
