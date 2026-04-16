local M = {}
local parts_config = v.config
local nodes = {}
local ref_nodes = {}
-- Subset of front chassis nodes used by apply_force_at_front_chassis to
-- inject heading-correction force at a point ahead of the CG without
-- directly pushing the hitch. Built at extension load.
local front_chassis_subset = {}

local last_node = 1
local nodes_per_frame = 32

local node_pos_thresh = 3
local node_pos_thresh_sqr = node_pos_thresh * node_pos_thresh

M.test_quat = quat(0.707, 0, 0, 0.707)

local function onExtensionLoaded()
  local force = obj:getPhysicsFPS()

  local ref = {
    v.data.refNodes[0].left,
    v.data.refNodes[0].up,
    v.data.refNodes[0].back,
    v.data.refNodes[0].ref,
  }

  local total_mass = 0
  local inverse_rot =  quat(obj:getRotation()):inversed()
  for _, node in pairs(v.data.nodes) do
    local node_mass = obj:getNodeMass(node.cid)
    local node_pos = inverse_rot * obj:getNodePosition(node.cid)
    table.insert(
      nodes,
      {
        node.cid,
        node_mass * force,  -- [2] FPS-scaled impulse factor (legacy primitives)
        true,               -- [3] eligibility flag
        node_pos,           -- [4] original local position
        node_mass           -- [5] real mass in kg (new primitive)
      }
    )
    --M.test_nodes_sync[node.cid] = vec3(obj:getNodePosition(node.cid))
    total_mass = total_mass + node_mass
  end

  for _, node in pairs(ref) do
    table.insert(
      ref_nodes,
      {
        node,
        total_mass * force / 4,
        true,
        inverse_rot * obj:getNodePosition(node)
      }
    )
  end

  -- Precompute the front chassis subset: a small set of non-wheel nodes
  -- forward of center, clustered around a point 35% of vehicle length
  -- forward of the geometric center. Used by apply_force_at_front_chassis
  -- to inject heading-correction force at a chassis point ahead of CG
  -- without directly pushing the hitch.
  local y_min, y_max = math.huge, -math.huge
  for _, n in ipairs(nodes) do
    if n[4].y < y_min then y_min = n[4].y end
    if n[4].y > y_max then y_max = n[4].y end
  end
  local wheelbase_proxy = y_max - y_min
  local y_center = (y_min + y_max) * 0.5
  local target_y = y_center + wheelbase_proxy * 0.35
  local target_local = vec3(0, target_y, 0)

  -- Build a set of wheel node cids to exclude from the subset
  local wheel_cids = {}
  if v.data.wheels then
    for _, w in pairs(v.data.wheels) do
      if type(w) == "table" then
        if w.node1 then wheel_cids[w.node1] = true end
        if w.node2 then wheel_cids[w.node2] = true end
      end
    end
  end

  local candidates = {}
  for _, n in ipairs(nodes) do
    if n[4].y > y_center and not wheel_cids[n[1]] then
      local dy = n[4].y - target_local.y
      local dx = n[4].x - target_local.x
      local dz = n[4].z - target_local.z
      local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
      table.insert(candidates, {node = n, dist = dist})
    end
  end
  table.sort(candidates, function(a, b) return a.dist < b.dist end)
  local N = math.min(6, #candidates)
  for i = 1, N do
    table.insert(front_chassis_subset, candidates[i].node)
  end
  print(string.format(
    "[KISS_VEHICLE %d] front_chassis_subset built: %d nodes, target_y=%.2f (y_min=%.2f y_max=%.2f y_center=%.2f)",
    obj:getID(), #front_chassis_subset, target_y, y_min, y_max, y_center
  ))
  for i, n in ipairs(front_chassis_subset) do
    print(string.format(
      "  [%d] cid=%d local=(%.2f, %.2f, %.2f) mass=%.1f",
      i, n[1], n[4].x, n[4].y, n[4].z, n[5]
    ))
  end

  -- Report total mass to GE so vehiclemanager can size coupler PD gains by
  -- the truck/trailer mass ratio at attach time.
  obj:queueGameEngineLua(string.format(
    "if vehiclemanager and vehiclemanager.set_vehicle_mass then vehiclemanager.set_vehicle_mass(%d, %f) end",
    obj:getID(), total_mass
  ))
end

  -- NOTE:
  -- This is a temperary solution. It's not great. We made it to release the mod.
  -- A better solution will be used in future versions
local function update_eligible_nodes()
  local inverse_rot =  quat(obj:getRotation()):inversed()
  for k=last_node, math.min(#nodes , last_node + nodes_per_frame) do
    local node = nodes[k]
    local local_node_pos = inverse_rot * obj:getNodePosition(node[1])
    local local_original_pos = node[4]
    node[3] = (local_node_pos - local_original_pos):squaredLength() < node_pos_thresh_sqr
    last_node = k
  end
  if last_node == #nodes then last_node = 1 end
end

local function update_transform_info()
  local r = quat(obj:getRotation())
  local p = obj:getPosition()
  
  local throttle_input = electrics.values.throttle_input or 0
  local brake_input = electrics.values.brake_input or 0
  if electrics.values.gearboxMode == "arcade" and electrics.values.gearIndex < 0 then
    throttle_input, brake_input = brake_input, throttle_input
  end
  
  local input = {
    vehicle_id = obj:getID() or 0,
    throttle_input = throttle_input,
    brake_input =  brake_input,
    clutch = electrics.values.clutch_input or 0,
    parkingbrake = electrics.values.parkingbrake_input or 0,
    steering_input = electrics.values.steering_input or 0,
  }
  local gearbox = kiss_gearbox.get_gearbox_data()
  local transform = {
    position  = {p.x, p.y, p.z},
    rotation  = {r.x, r.y, r.z, r.w},
    input = input,
    gearbox = gearbox,
    vel_pitch = obj:getPitchAngularVelocity(),
    vel_roll  = obj:getRollAngularVelocity(),
    vel_yaw   = obj:getYawAngularVelocity(),
  }

  -- Phase 3: if cluster discovery has run and cluster_sender is
  -- available, compute per-cluster poses and attach them. The GE
  -- side includes these in the VehicleUpdate packet. Empty table
  -- for single-cluster vehicles or when discovery hasn't finished.
  if cluster_state and cluster_state.clusters and #cluster_state.clusters > 1
     and cluster_sender then
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
    -- Compute world poses for all clusters first, then convert
    -- non-root clusters to parent-relative. BFS order (guaranteed
    -- by cluster_topology) means the parent's world pose is always
    -- computed before any of its children.
    local world_poses = {}
    for _, c in ipairs(cluster_state.clusters) do
      if c.masses and c.node_offsets_local then
        world_poses[c.id] = cluster_sender.compute_pose(c, c.masses, get_pos, get_vel)
      end
    end
    local cluster_poses = {}
    for _, c in ipairs(cluster_state.clusters) do
      local wp = world_poses[c.id]
      if wp then
        local pos, rot, lv, av
        if c.parent_id and world_poses[c.parent_id] then
          -- Parent-relative: preserve the hinge angle exactly.
          local pp = world_poses[c.parent_id]
          local inv_rot = pp.rot:inversed()
          pos = inv_rot * (wp.pos - pp.pos)
          rot = inv_rot * wp.rot
          lv  = inv_rot * (wp.lin_vel - pp.lin_vel)
          av  = inv_rot * (wp.ang_vel - pp.ang_vel)
        else
          -- Root cluster: world frame.
          pos = wp.pos
          rot = wp.rot
          lv  = wp.lin_vel
          av  = wp.ang_vel
        end
        table.insert(cluster_poses, {
          id  = c.id,
          pr  = c.parent_id or 0,  -- 0 = root (world frame)
          pos = {pos.x, pos.y, pos.z},
          rot = {rot.x, rot.y, rot.z, rot.w},
          lv  = {lv.x, lv.y, lv.z},
          av  = {av.x, av.y, av.z},
        })
      end
    end
    if #cluster_poses > 0 then
      transform.clusters = cluster_poses
    end
  end

  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", " .. string.format("%q", jsonEncode(transform)) .. ")")
end

local function apply_linear_velocity(x, y, z)
  local velocity = vec3(x, y, z)
  local force = float3(0, 0, 0)
  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      local result = velocity * node[2]
      force:set(result.x, result.y, result.z)
      obj:applyForceVector(node[1], force)
    end
  end
end

local function apply_linear_velocity_ang_torque(x, y, z, pitch, roll, yaw)
  local velocity = vec3(x, y, z)
  local nodes = nodes
  -- 0.1 seems like the safe value we can use for low velocities
  -- NOTE: Doesn't work as well as expected
  if velocity:length() < 0.01 then
    --nodes = ref_nodes
  end
  local rot = vec3(pitch, roll, yaw):rotated(quat(obj:getRotation()))
  local node_position = vec3()
  local force = float3(0, 0, 0)
  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      node_position:set(obj:getNodePosition(node[1]))
      local result = (velocity + node_position:cross(rot)) * node[2]
      force:set(result.x, result.y, result.z)
      obj:applyForceVector(node[1], force)
    end
  end
end

-- Apply a total world-space force F = (fx, fy, fz) distributed across the
-- precomputed front chassis subset, mass-weighted by real node mass. The
-- resultant is the full F acting at the subset's mass-weighted centroid
-- (approximately the target_local point computed at extension load).
--
-- Unlike apply_linear_velocity_ang_torque, this function does NOT use a
-- cross-product velocity snap, so it produces a smooth chassis-level force
-- that propagates to the rest of the vehicle via normal beam dynamics.
-- When called with a lateral force at a front-of-CG chassis point, it
-- creates a real geometric torque around the CG (via the lever arm) and
-- the front tires contribute additional yaw moment via slip angle — both
-- in the same direction. The hitch node is behind the CG and never
-- directly pushed; it follows chassis rotation through beam propagation
-- without the per-tick impulsive kick that causes jackknife.
local function apply_force_at_front_chassis(fx, fy, fz)
  if not front_chassis_subset or #front_chassis_subset == 0 then return end
  local total_mass = 0
  for k = 1, #front_chassis_subset do
    local n = front_chassis_subset[k]
    if n[3] then total_mass = total_mass + n[5] end
  end
  if total_mass <= 0 then return end
  local force = float3(0, 0, 0)
  for k = 1, #front_chassis_subset do
    local n = front_chassis_subset[k]
    if n[3] then
      local w = n[5] / total_mass
      force:set(fx * w, fy * w, fz * w)
      obj:applyForceVector(n[1], force)
    end
  end
end

local function send_vehicle_config()
  local config = v.config
  local r = quat(obj:getRotation())
  local p = obj:getPosition()
  local data = {
    position = {p.x, p.y, p.z},
    rotation = {r.x, r.y, r.z, r.w},
  }
  obj:queueGameEngineLua("vehiclemanager.send_vehicle_config_inner("..obj:getID()..", " .. string.format("%q", jsonEncode(config)) .. ", " .. string.format("%q", jsonEncode(data)) .. ")")
end

M.update_transform_info = update_transform_info
M.apply_linear_velocity_ang_torque = apply_linear_velocity_ang_torque
M.apply_force_at_front_chassis = apply_force_at_front_chassis
M.update_eligible_nodes = update_eligible_nodes
M.apply_linear_velocity = apply_linear_velocity
M.onExtensionLoaded = onExtensionLoaded
M.set_reference = set_reference
M.save_state = save_state
M.send_vehicle_config = send_vehicle_config
return M
