local M = {}

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

  -- Experemental.
  -- This allows to set rotation without affecting vehicle velocity, the downside is that it can make vehicle extremly unstable if called too often/if angle is too big
local function set_rotation(x, y, z, w)
  local nodes_table = {}
  for _, node in pairs(v.data.nodes) do
    local pos = obj:getNodePositionRelative(node.cid)
    nodes_table[node.cid] = {pos.x, pos.y, pos.z}
  end
  obj:queueGameEngineLua("vehiclemanager.rotate_nodes(\'"..jsonEncode(nodes_table).."\', "..obj:getID()..", "..x..", "..y..", "..z..", "..w..")")
end

local function apply_full_velocity(x, y, z, pitch, roll, yaw)
  local velocity = vec3(x, y, z)
  local force = obj:getPhysicsFPS()
  local rot = vec3(pitch, roll, yaw):rotated(quat(obj:getRotation()))
  for _, node in pairs(v.data.nodes) do
    local node_position = vec3(obj:getNodePosition(node.cid))
    local force = (velocity + node_position:cross(rot)) * obj:getNodeMass(node.cid) * force
    obj:applyForceVector(node.cid, force:toFloat3())
  end
end

local function kill_velocity(strength)
  local fps = obj:getPhysicsFPS()
  for _, node in pairs(v.data.nodes) do
    local force = vec3(obj:getNodeVelocityVector(node.cid)) * obj:getNodeMass(node.cid) * -fps * (strength or 1)
    obj:applyForceVector(node.cid, force:toFloat3())
  end
end

M.update_transform_info = update_transform_info
M.set_rotation = set_rotation
M.apply_full_velocity = apply_full_velocity
M.kill_velocity = kill_velocity
M.onInit = init

return M
