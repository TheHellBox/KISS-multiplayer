-- Tests for cluster_receiver.lua — per-node velocity-matching force.
--
-- Strategy: construct a target pose, pick a current node state
-- that differs from the target, compute the force, verify that
-- applying the force over one tick (F*dt → Δv) closes the gap.

local cluster_receiver = require("cluster_receiver")

local T = {}

-- ============================================================
-- Tests: compute_node_force
-- ============================================================

function T.test_zero_error_zero_force()
  local rest = vec3(1, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  local cur_pos = vec3(1, 0, 0)  -- exactly at target
  local cur_vel = vec3(0, 0, 0)
  local f = cluster_receiver.compute_node_force(
    rest, pose, 1.0, cur_pos, cur_vel, 0.005, 50.0, 50000
  )
  assert(f:length() < 1e-6, "expected zero force, got " .. tostring(f))
end

function T.test_linear_position_error_produces_pull()
  -- Target at origin, node at (1,0,0), rest offset (0,0,0).
  -- Expected pull is -x direction with magnitude:
  --   vel_err = kp_pos * pos_err = 50 * (-1,0,0) = (-50, 0, 0)
  --   force   = mass * vel_err / dt = 1 * (-50,0,0) / 0.005 = (-10000, 0, 0)
  -- clamped to max_force=50000.
  local rest = vec3(0, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  local cur_pos = vec3(1, 0, 0)
  local cur_vel = vec3(0, 0, 0)
  local f = cluster_receiver.compute_node_force(
    rest, pose, 1.0, cur_pos, cur_vel, 0.005, 50.0, 50000
  )
  assert(f.x < 0, "expected -x pull, got " .. tostring(f))
  assert(math.abs(f.y) < 1e-6, "y force leaked")
  assert(math.abs(f.z) < 1e-6, "z force leaked")
end

function T.test_velocity_error_produces_opposing_force()
  -- Node is at target pos, but moving away at +x. Force should
  -- decelerate it, i.e., negative x component.
  local rest = vec3(0, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  local cur_pos = vec3(0, 0, 0)
  local cur_vel = vec3(5, 0, 0)
  local f = cluster_receiver.compute_node_force(
    rest, pose, 1.0, cur_pos, cur_vel, 0.005, 50.0, 50000
  )
  assert(f.x < 0, "expected decel, got " .. tostring(f))
end

function T.test_rotated_target()
  -- Target pose has a 90° yaw. Node's rest offset is (1,0,0),
  -- so in world frame the target position should be at the
  -- rotated offset, i.e. (0, 1, 0). Node currently at (1,0,0)
  -- should be pulled toward (0,1,0).
  local rest = vec3(1, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0),
    rot = quatFromAxisAngle(vec3(0, 0, 1), math.rad(90)),
    lin_vel = vec3(0, 0, 0),
    ang_vel = vec3(0, 0, 0),
  }
  local cur_pos = vec3(1, 0, 0)
  local cur_vel = vec3(0, 0, 0)
  local f = cluster_receiver.compute_node_force(
    rest, pose, 1.0, cur_pos, cur_vel, 0.005, 50.0, 50000
  )
  -- Expected target pos ≈ (0, 1, 0). pos_err ≈ (-1, 1, 0).
  -- Force should point along pos_err direction (roughly).
  assert(f.x < 0, "expected -x pull")
  assert(f.y > 0, "expected +y pull")
end

function T.test_angular_velocity_produces_tangential_target()
  -- Target pose has ang_vel = (0,0,ω). Node at rest offset (1,0,0).
  -- In world frame, target velocity = ω × (1,0,0) = (0, ω, 0).
  -- Node currently at target pos with zero velocity should be
  -- accelerated in +y by (mass/dt) * ω.
  local rest = vec3(1, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 3.0),
  }
  local cur_pos = vec3(1, 0, 0)
  local cur_vel = vec3(0, 0, 0)
  local f = cluster_receiver.compute_node_force(
    rest, pose, 1.0, cur_pos, cur_vel, 0.005, 0.0, 50000
  )
  -- Expected: target_vel = (0, 3, 0), vel_err = (0, 3, 0),
  -- force = 1.0 * (0, 3, 0) / 0.005 = (0, 600, 0)
  assert(math.abs(f.x) < 1e-6, "x leaked: " .. tostring(f))
  assert(math.abs(f.y - 600) < 1e-3, "y: " .. tostring(f))
  assert(math.abs(f.z) < 1e-6, "z leaked")
end

function T.test_force_clamped_per_component()
  -- Huge position error; force must clamp to MAX_FORCE_PER_NODE_N.
  local rest = vec3(0, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  local cur_pos = vec3(1000, 0, 0)
  local cur_vel = vec3(0, 0, 0)
  local max_f = 50000
  local f = cluster_receiver.compute_node_force(
    rest, pose, 1.0, cur_pos, cur_vel, 0.005, 50.0, max_f
  )
  assert(math.abs(f.x) <= max_f + 1e-6, "x not clamped: " .. tostring(f))
end

function T.test_zero_mass_no_force()
  local rest = vec3(0, 0, 0)
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  local f = cluster_receiver.compute_node_force(
    rest, pose, 0, vec3(10,0,0), vec3(0,0,0), 0.005, 50.0, 50000
  )
  assert(f:length() < 1e-9, "massless node should receive no force")
end

function T.test_one_tick_convergence()
  -- Apply the computed force; verify that after one tick (Δv = F*dt/m)
  -- the new velocity matches the target velocity EXACTLY (since
  -- the force is literally mass*vel_err/dt). This is the core
  -- invariant of the velocity-matching formula.
  local rest = vec3(0.3, -0.5, 0.2)
  local pose = {
    pos = vec3(10, 20, 5),
    rot = quatFromAxisAngle(vec3(0,0,1), math.rad(25)),
    lin_vel = vec3(2, 1, 0),
    ang_vel = vec3(0.1, 0.2, 0.3),
  }
  local cur_pos = vec3(11, 20, 5)  -- offset from target
  local cur_vel = vec3(0, 0, 0)
  local mass = 5
  local dt = 0.005
  local f = cluster_receiver.compute_node_force(
    rest, pose, mass, cur_pos, cur_vel, dt, 50.0, 1e12
  )
  -- Δv = f*dt/m
  local dv = vec3(f.x * dt / mass, f.y * dt / mass, f.z * dt / mass)
  local new_vel = cur_vel + dv
  -- Expected target velocity (same formula as inside compute_node_force)
  local world_off = pose.rot * rest
  local target_pos = pose.pos + world_off
  local expected_vel = pose.lin_vel + pose.ang_vel:cross(world_off)
    + (target_pos - cur_pos) * 50.0
  local err = (new_vel - expected_vel):length()
  assert(err < 1e-6, string.format(
    "one-tick convergence failed: err=%.6g", err))
end

-- ============================================================
-- Tests: apply_cluster_forces
-- ============================================================

function T.test_apply_cluster_forces_iterates_all_nodes()
  local cluster = {
    id = 1,
    nodes = {1, 2, 3, 4},
    node_offsets_local = {
      [1] = vec3(1, 0, 0), [2] = vec3(-1, 0, 0),
      [3] = vec3(0, 1, 0), [4] = vec3(0, -1, 0),
    },
  }
  local masses = {[1]=1, [2]=1, [3]=1, [4]=1}
  local pose = {
    pos = vec3(5, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  -- Current positions are the rest offsets (not translated to
  -- pose.pos=5). Every node should get pulled toward +x.
  local get_pos = function(cid) return cluster.node_offsets_local[cid] end
  local get_vel = function(_) return vec3(0, 0, 0) end
  local applied = {}
  local apply_force = function(cid, f) applied[cid] = f end

  local sum_f, sum_err_sq = cluster_receiver.apply_cluster_forces(
    cluster, pose, masses, 0.005,
    {KP_POS = 50.0, MAX_FORCE_PER_NODE_N = 1e9},
    get_pos, get_vel, apply_force
  )

  assert(sum_f > 0, "total force should be nonzero")
  assert(sum_err_sq > 0, "position error should be nonzero")
  for _, cid in ipairs(cluster.nodes) do
    assert(applied[cid] ~= nil, "missing force for cid " .. cid)
    assert(applied[cid].x > 0, "cid " .. cid .. " should be pulled +x")
  end
end

function T.test_apply_cluster_forces_uses_const_defaults()
  local cluster = {
    id = 1,
    nodes = {1},
    node_offsets_local = {[1] = vec3(0, 0, 0)},
  }
  local masses = {[1] = 1}
  local pose = {
    pos = vec3(0, 0, 0), rot = quat(0, 0, 0, 1),
    lin_vel = vec3(0, 0, 0), ang_vel = vec3(0, 0, 0),
  }
  local get_pos = function() return vec3(0.001, 0, 0) end
  local get_vel = function() return vec3(0, 0, 0) end
  local applied
  local apply_force = function(_, f) applied = f end
  -- Pass nil const; should use KP_POS=50, MAX_FORCE=50000 defaults
  cluster_receiver.apply_cluster_forces(
    cluster, pose, masses, 0.005, nil, get_pos, get_vel, apply_force
  )
  assert(applied ~= nil, "force should be applied")
  assert(applied.x < 0, "should pull -x: " .. tostring(applied))
end

-- ============================================================
-- Tests: target_from_transform adapter
-- ============================================================

function T.test_target_from_transform_all_fields()
  -- Identity rotation: body-frame ang_vel should pass through
  -- unchanged in world frame.
  local xform = {
    position = vec3(1, 2, 3),
    rotation = quat(0, 0, 0, 1),
    velocity = vec3(10, 0, 0),
    angular_velocity = vec3(0.1, 0.2, 0.3),
  }
  local pose = cluster_receiver.target_from_transform(xform)
  assert(pose.pos == xform.position)
  assert(pose.rot == xform.rotation)
  assert(pose.lin_vel == xform.velocity)
  assert(math.abs(pose.ang_vel.x - 0.1) < 1e-6)
  assert(math.abs(pose.ang_vel.y - 0.2) < 1e-6)
  assert(math.abs(pose.ang_vel.z - 0.3) < 1e-6)
end

function T.test_target_from_transform_rotates_ang_vel_to_world()
  -- 90° yaw puts the body X axis along world Y. A body-frame ω
  -- along body X (pitch) becomes world ω along world Y after
  -- the rotation.
  local rot = quatFromAxisAngle(vec3(0, 0, 1), math.rad(90))
  local xform = {
    position = vec3(0, 0, 0),
    rotation = rot,
    velocity = vec3(0, 0, 0),
    angular_velocity = vec3(1, 0, 0),  -- body-frame pitch
  }
  local pose = cluster_receiver.target_from_transform(xform)
  -- Body X (1,0,0) rotated 90° about Z → world Y (0,1,0).
  assert(math.abs(pose.ang_vel.x) < 1e-6,
         "x should be ~0 after 90° yaw: " .. tostring(pose.ang_vel))
  assert(math.abs(pose.ang_vel.y - 1) < 1e-6,
         "y should be ~1: " .. tostring(pose.ang_vel))
  assert(math.abs(pose.ang_vel.z) < 1e-6,
         "z should be ~0: " .. tostring(pose.ang_vel))
end

function T.test_target_from_transform_missing_ang_vel()
  local xform = {
    position = vec3(0, 0, 0),
    rotation = quat(0, 0, 0, 1),
    velocity = vec3(0, 0, 0),
    -- no angular_velocity
  }
  local pose = cluster_receiver.target_from_transform(xform)
  assert(pose.ang_vel.x == 0 and pose.ang_vel.y == 0 and pose.ang_vel.z == 0,
         "missing ang_vel should default to zero")
end

function T.test_target_from_transform_nil_input()
  assert(cluster_receiver.target_from_transform(nil) == nil)
end

return T
