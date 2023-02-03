local M = {}
local ownership = false
local ignore_attachment = false
local ignore_detachment = false

local function attach_coupler(node)
  local node = v.data.nodes[node]
  obj:attachCoupler(node.cid, node.couplerTag or "", node.couplerStrength or 1000000, node.couplerRadius or 0.2, 0, node.couplerLatchSpeed or 0.3, node.couplerTargets or 0)
  ignore_attachment = true
end

local function detach_coupler(node)
  obj:detachCoupler(node, 0)
  ignore_detachment = true
end

local function onCouplerAttached(node_id, obj2_id, obj2_node_id)
  if not ownership then return end
  if ignore_attachment then
    ignore_attachment = false
    return
  end
  local data = {
    obj_a = obj:getID(),
    obj_b = obj2_id,
    node_a_id = node_id,
    node_b_id = obj2_node_id
  }
  obj:queueGameEngineLua("vehiclemanager.attach_coupler_inner(\'"..jsonEncode(data).."\')")
end

local function onCouplerDetached(node_id, obj2_id, obj2_node_id)
  if not ownership then return end
  if ignore_detachment then
    ignore_detachment = false
    return
  end
  local data = {
    obj_a = obj:getID(),
    obj_b = obj2_id,
    node_a_id = node_id,
    node_b_id = obj2_node_id
  }
   obj:queueGameEngineLua("vehiclemanager.detach_coupler_inner(\'"..jsonEncode(data).."\')")
end

local function kissUpdateOwnership(owned)
  ownership = owned
end

M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.kissUpdateOwnership = kissUpdateOwnership
M.attach_coupler = attach_coupler
M.detach_coupler = detach_coupler

return M
