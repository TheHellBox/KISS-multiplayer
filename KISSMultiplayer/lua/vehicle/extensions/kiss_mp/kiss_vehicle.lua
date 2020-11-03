local M = {}
local parts_config = v.config
local nodes = {}

local function kissInit()
  for _, node in pairs(v.data.nodes) do
    local mass = obj:getNodeMass(node.cid)
    table.insert(
      nodes,
      {
        node.cid,
        vec3(mass, mass, mass):toFloat3()
      }
    )
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
  local velocity = vec3(x, y, z):toFloat3()
  local force = obj:getPhysicsFPS()
  local force = vec3(force, force, force):toFloat3()
  local rot = vec3(pitch, roll, yaw):rotated(quat(obj:getRotation())):toFloat3()
  for k=1, #nodes do
    local node = nodes[k]
    local node_position = obj:getNodePosition(node[1])
    local force = (velocity + node_position:cross(rot)) * node[2] * force
    obj:applyForceVector(node[1], force)
  end
end

M.update_transform_info = update_transform_info
M.apply_full_velocity = apply_full_velocity
M.kissInit = kissInit

return M
