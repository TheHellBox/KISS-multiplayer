local M = {}

local generation = 0

-- Wtf I need to do this. BeamNG devs, that's crap!
local function update_rotation()
  local r = obj:getRotation()
  obj:queueGameEngineLua("vehiclemanager.push_rotation("..obj:getID()..", "..r.x..", "..r.y..", "..r.z..", "..r.w..")")
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

local function apply_velocity(x, y, z, force)
  local velocity = vec3(x, y, z)
  for _, node in pairs(v.data.nodes) do
    local force = velocity * obj:getNodeMass(node.cid) * force
    obj:applyForceVector(node.cid, force:toFloat3())
  end
end

local function kill_velocity(strength)
  for _, node in pairs(v.data.nodes) do
    local force = vec3(obj:getNodeVelocityVector(node.cid)) * -2000 * (strength or 1)
    obj:applyForceVector(node.cid, force:toFloat3())
  end
end

M.update_rotation = update_rotation
M.set_rotation = set_rotation
M.apply_velocity = apply_velocity
M.kill_velocity = kill_velocity

return M
