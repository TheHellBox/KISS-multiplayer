-- Tests for cluster_sender.lua — pose synthesis from live node
-- positions + velocities. Verifies the forward path: given a
-- rigid-body motion (known rot, lin_vel, ang_vel), synthesize node
-- positions/velocities and check the sender recovers the same.

-- cluster_sender reads cluster_math from _G (matching BeamNG's
-- loadModulesInDirectory global-injection pattern). Install it
-- before loading cluster_sender so get_cluster_math() resolves.
_G.cluster_math = require("cluster_math")
local cluster_sender = require("cluster_sender")

local T = {}

-- ============================================================
-- Helpers
-- ============================================================

local function make_cluster(offsets)
  local cluster = {id = 1, nodes = {}, node_offsets_local = {}}
  for cid, off in pairs(offsets) do
    table.insert(cluster.nodes, cid)
    cluster.node_offsets_local[cid] = off
  end
  table.sort(cluster.nodes)
  return cluster
end

local function unit_masses(cluster)
  local m = {}
  for _, cid in ipairs(cluster.nodes) do m[cid] = 1.0 end
  return m
end

-- 8 corners of a unit cube — well-conditioned (spans 3D, non-degenerate
-- inertia tensor).
local function cube_cluster()
  return make_cluster({
    [1] = vec3(-1, -1, -1), [2] = vec3( 1, -1, -1),
    [3] = vec3( 1,  1, -1), [4] = vec3(-1,  1, -1),
    [5] = vec3(-1, -1,  1), [6] = vec3( 1, -1,  1),
    [7] = vec3( 1,  1,  1), [8] = vec3(-1,  1,  1),
  })
end

-- Given target rot / lin_vel / ang_vel / centroid, synthesize a
-- consistent set of node positions and velocities.
-- pos_k = centroid + rot * rest_offset_k
-- vel_k = lin_vel + ang_vel × (rot * rest_offset_k)
local function make_rigid_body_state(cluster, rot, lin_vel, centroid, ang_vel)
  local positions = {}
  local velocities = {}
  for _, cid in ipairs(cluster.nodes) do
    local rest = cluster.node_offsets_local[cid]
    local world_off = rot * rest
    positions[cid] = centroid + world_off
    -- v = v_cm + ω × r
    velocities[cid] = lin_vel + ang_vel:cross(world_off)
  end
  return function(cid) return positions[cid] end,
         function(cid) return velocities[cid] end
end

local function quats_equivalent(q1, q2, tol)
  tol = tol or 1e-4
  local d1 = math.abs(q1.x - q2.x) + math.abs(q1.y - q2.y)
             + math.abs(q1.z - q2.z) + math.abs(q1.w - q2.w)
  local d2 = math.abs(q1.x + q2.x) + math.abs(q1.y + q2.y)
             + math.abs(q1.z + q2.z) + math.abs(q1.w + q2.w)
  return math.min(d1, d2) < tol
end

local function vec3_close(a, b, tol)
  tol = tol or 1e-4
  return (a - b):length() < tol
end

-- ============================================================
-- Tests
-- ============================================================

function T.test_stationary_identity()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local rot = quat(0, 0, 0, 1)
  local lin_vel = vec3(0, 0, 0)
  local ang_vel = vec3(0, 0, 0)
  local centroid = vec3(0, 0, 0)
  local get_pos, get_vel = make_rigid_body_state(cluster, rot, lin_vel, centroid, ang_vel)
  local pose = cluster_sender.compute_pose(cluster, masses, get_pos, get_vel)
  assert(vec3_close(pose.pos, centroid), "pos: " .. tostring(pose.pos))
  assert(quats_equivalent(pose.rot, rot), "rot: " .. tostring(pose.rot))
  assert(vec3_close(pose.lin_vel, lin_vel), "lin_vel: " .. tostring(pose.lin_vel))
  assert(vec3_close(pose.ang_vel, ang_vel), "ang_vel: " .. tostring(pose.ang_vel))
  assert(math.abs(pose.total_mass - 8) < 1e-9, "total_mass: " .. tostring(pose.total_mass))
end

function T.test_pure_translation()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local centroid = vec3(100, 200, 50)
  local lin_vel = vec3(10, -5, 3)
  local get_pos, get_vel = make_rigid_body_state(
    cluster, quat(0,0,0,1), lin_vel, centroid, vec3(0,0,0))
  local pose = cluster_sender.compute_pose(cluster, masses, get_pos, get_vel)
  assert(vec3_close(pose.pos, centroid), "pos: " .. tostring(pose.pos))
  assert(vec3_close(pose.lin_vel, lin_vel), "lin_vel: " .. tostring(pose.lin_vel))
  assert(vec3_close(pose.ang_vel, vec3(0,0,0)), "ang_vel: " .. tostring(pose.ang_vel))
end

function T.test_pure_rotation()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local rot = quatFromAxisAngle(vec3(0, 0, 1), math.rad(30))
  local centroid = vec3(0, 0, 0)
  local ang_vel = vec3(0, 0, 2.0)  -- 2 rad/s yaw
  local get_pos, get_vel = make_rigid_body_state(
    cluster, rot, vec3(0,0,0), centroid, ang_vel)
  local pose = cluster_sender.compute_pose(cluster, masses, get_pos, get_vel)
  assert(quats_equivalent(pose.rot, rot), "rot: " .. tostring(pose.rot))
  assert(vec3_close(pose.ang_vel, ang_vel, 1e-3),
         "ang_vel: expected " .. tostring(ang_vel) .. " got " .. tostring(pose.ang_vel))
end

function T.test_full_rigid_motion()
  local cluster = cube_cluster()
  local masses = unit_masses(cluster)
  local rot = quatFromAxisAngle(vec3(0.3, 0.5, 0.8):normalized(), math.rad(47))
  local centroid = vec3(10, 20, 5)
  local lin_vel = vec3(3, 2, -1)
  local ang_vel = vec3(0.5, -0.3, 1.2)
  local get_pos, get_vel = make_rigid_body_state(
    cluster, rot, lin_vel, centroid, ang_vel)
  local pose = cluster_sender.compute_pose(cluster, masses, get_pos, get_vel)
  assert(vec3_close(pose.pos, centroid, 1e-4), "pos")
  assert(quats_equivalent(pose.rot, rot, 1e-3), "rot: " .. tostring(pose.rot))
  assert(vec3_close(pose.lin_vel, lin_vel, 1e-4), "lin_vel")
  assert(vec3_close(pose.ang_vel, ang_vel, 1e-3),
         "ang_vel: expected " .. tostring(ang_vel) .. " got " .. tostring(pose.ang_vel))
end

function T.test_nonuniform_mass_distribution()
  local cluster = cube_cluster()
  local masses = {[1]=1, [2]=2, [3]=3, [4]=4, [5]=5, [6]=6, [7]=7, [8]=8}
  -- Rest offsets are still symmetric about origin, but mass-weighted
  -- centroid will NOT be at origin. Synthesize positions with the
  -- actual mass-weighted centroid. Use unit rotation and test that
  -- sender's total_mass matches and the position is consistent.
  -- Expected centroid from rest offsets weighted by mass:
  local total = 0
  local cx, cy, cz = 0, 0, 0
  for cid, off in pairs(cluster.node_offsets_local) do
    local m = masses[cid]
    cx = cx + off.x * m
    cy = cy + off.y * m
    cz = cz + off.z * m
    total = total + m
  end
  -- This test uses rest offsets as world positions (identity rot,
  -- zero lin_vel, zero ang_vel, zero centroid shift).
  local get_pos = function(cid) return cluster.node_offsets_local[cid] end
  local get_vel = function(_)   return vec3(0, 0, 0) end
  local pose = cluster_sender.compute_pose(cluster, masses, get_pos, get_vel)
  assert(math.abs(pose.total_mass - total) < 1e-9, "total_mass")
  local expected_centroid = vec3(cx / total, cy / total, cz / total)
  assert(vec3_close(pose.pos, expected_centroid),
         "pos: " .. tostring(pose.pos) .. " vs " .. tostring(expected_centroid))
end

function T.test_zero_mass_returns_zero_pose()
  local cluster = cube_cluster()
  local masses = {}
  for _, cid in ipairs(cluster.nodes) do masses[cid] = 0 end
  local get_pos = function() return vec3(0, 0, 0) end
  local get_vel = function() return vec3(0, 0, 0) end
  local pose = cluster_sender.compute_pose(cluster, masses, get_pos, get_vel)
  assert(pose.total_mass == 0)
  assert(vec3_close(pose.ang_vel, vec3(0,0,0)))
end

function T.test_compute_all_poses_iterates()
  local c1 = cube_cluster()
  c1.id = 1
  local c2 = make_cluster({
    [10] = vec3( 0.5,  0.5,  0),
    [11] = vec3(-0.5,  0.5,  0),
    [12] = vec3( 0.5, -0.5,  0),
    [13] = vec3(-0.5, -0.5,  0),
    [14] = vec3( 0,    0,    1),
    [15] = vec3( 0,    0,   -1),
  })
  c2.id = 7  -- sparse cluster id (reservation #1 from roadmap)
  local clusters = {c1, c2}
  local masses = {}
  for _, c in ipairs(clusters) do
    for _, cid in ipairs(c.nodes) do masses[cid] = 1.0 end
  end
  local get_pos = function(cid)
    for _, c in ipairs(clusters) do
      if c.node_offsets_local[cid] then return c.node_offsets_local[cid] end
    end
    return vec3(0,0,0)
  end
  local get_vel = function() return vec3(0, 0, 0) end
  local poses = cluster_sender.compute_all_poses(clusters, masses, get_pos, get_vel)
  assert(poses[1] ~= nil, "pose for id=1 missing")
  assert(poses[7] ~= nil, "pose for id=7 missing (sparse cluster id)")
  assert(poses[7].total_mass == 6)
end

return T
