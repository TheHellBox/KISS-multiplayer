local M = {}
local parts_config = v.config
local nodes = {}

local function kissInit()
  for _, node in pairs(v.data.nodes) do
    table.insert(nodes, node)
  end
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
  local velocity = vec3(x, y, z)
  local force = obj:getPhysicsFPS()
  local rot = vec3(pitch, roll, yaw):rotated(quat(obj:getRotation()))
  for k=1, #nodes do
    local node = nodes[k]
    local node_position = vec3(obj:getNodePosition(node.cid))
    local force = (velocity + node_position:cross(rot)) * obj:getNodeMass(node.cid) * force
    obj:applyForceVector(node.cid, force:toFloat3())
  end
end

M.update_transform_info = update_transform_info
M.apply_full_velocity = apply_full_velocity
M.kissInit = kissInit

return M
