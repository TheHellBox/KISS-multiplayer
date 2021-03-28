local M = {}
local parts_config = v.config
local nodes = {}
local ref_nodes = {}

local last_node = 1
local nodes_per_frame = 32
local node_pos_thresh = 32

M.test_quat = quat(0.707, 0, 0, 0.707)

local function kissInit()
  local force = obj:getPhysicsFPS()

  local ref = {
    v.data.refNodes[0].left,
    v.data.refNodes[0].up,
    v.data.refNodes[0].back,
    v.data.refNodes[0].ref,
  }

  local total_mass = 0
  for _, node in pairs(v.data.nodes) do
    local node_mass = obj:getNodeMass(node.cid)
    table.insert(
      nodes,
      {
        node.cid,
        node_mass * force,
        true
      }
    )
    M.test_nodes_sync[node.cid] = vec3(obj:getNodePosition(node.cid))
    total_mass = total_mass + node_mass
  end

  for _, node in pairs(ref) do
    table.insert(
      ref_nodes,
      {
        node,
        total_mass * force / 4,
        true,

      }
    )
  end
end

  -- NOTE:
  -- This is a temperary solution. It's not great. We made it to release the mod.
  -- A better solution will be used in future versions
local function update_eligible_nodes()
  for k=last_node, math.min(#nodes , last_node + nodes_per_frame) do
    local node = nodes[k]
    local node_position = obj:getNodePosition(node[1])
    node[3] = node_position:length() < node_pos_thresh
    last_node = k
  end
  if last_node == #nodes then last_node = 1 end
end

local function update_transform_info()
  local r = quat(obj:getRotation())
  local transform = {
    rotation  = {r.x, r.y, r.z, r.w},
    vel_pitch = obj:getPitchAngularVelocity(),
    vel_roll  = obj:getRollAngularVelocity(),
    vel_yaw   = obj:getYawAngularVelocity(),
  }
  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", \'"..jsonEncode(transform).."\')")
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
  if velocity:length() < 0.2 then
    nodes = ref_nodes
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

M.update_transform_info = update_transform_info
M.apply_linear_velocity_ang_torque = apply_linear_velocity_ang_torque
M.update_eligible_nodes = update_eligible_nodes
M.apply_linear_velocity = apply_linear_velocity
M.kissInit = kissInit
M.set_reference = set_reference
M.save_state = save_state

return M
