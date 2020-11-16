local M = {}
local parts_config = v.config
local nodes = {}

local last_node = 1
local nodes_per_frame = 32
local node_pos_thresh = 32

local function kissInit()
  local force = obj:getPhysicsFPS()
  force = vec3(force, force, force):toFloat3()
  for _, node in pairs(v.data.nodes) do
    local mass = obj:getNodeMass(node.cid)
    table.insert(
      nodes,
      {
        node.cid,
        vec3(mass, mass, mass):toFloat3() * force,
        true
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
  local r = obj:getRotation()
  local transform = {
    rotation  = {r.x, r.y, r.z, r.w},
    vel_pitch = obj:getPitchAngularVelocity(),
    vel_roll  = obj:getRollAngularVelocity(),
    vel_yaw   = obj:getYawAngularVelocity(),
  }
  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", \'"..jsonEncode(transform).."\')")
end

local function apply_full_velocity(x, y, z, pitch, roll, yaw)
  local velocity = vec3(x, y, z):toFloat3()
  local rot = vec3(pitch, roll, yaw):rotated(quat(obj:getRotation())):toFloat3()
  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      local node_position = obj:getNodePosition(node[1])
      local force = (velocity + node_position:cross(rot)) * node[2]
      obj:applyForceVector(node[1], force)
    end
  end
end

M.update_transform_info = update_transform_info
M.apply_full_velocity = apply_full_velocity
M.update_eligible_nodes = update_eligible_nodes
M.kissInit = kissInit

return M
