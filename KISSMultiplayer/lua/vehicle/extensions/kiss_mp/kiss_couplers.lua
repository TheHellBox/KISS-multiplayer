local M = {}
local ownership = false
local ignore_attachment = false
local ignore_detachment = false

local ignored_couplers = {}

local function ignore_coupler_node(node) 
  ignored_couplers[node] = true
end

local function attach_coupler(node_idx)
  local node = v.data.nodes[node_idx]
  if not node then
    print(string.format("[KISS_COUPLER] ERROR: no node at index %d on veh=%d", node_idx, obj:getID()))
    -- Dump available coupler nodes
    for i, n in pairs(v.data.nodes) do
      if n.couplerTag then
        print(string.format("[KISS_COUPLER]   available coupler: idx=%s cid=%d tag=%s", tostring(i), n.cid, n.couplerTag))
      end
    end
    return
  end
  print(string.format("[KISS_COUPLER] attach_coupler veh=%d idx=%d cid=%d tag=%s", obj:getID(), node_idx, node.cid, node.couplerTag or "none"))
  obj:attachCoupler(node.cid, node.couplerTag or "", node.couplerStrength or 1000000, 1.0, 0, node.couplerLatchSpeed or 0.3, node.couplerTargets or 0)
  ignore_attachment = true
end

local function detach_coupler(node)
  print(string.format("[KISS_COUPLER] detach_coupler called on veh=%d node=%d", obj:getID(), node))
  obj:detachCoupler(node, 0)
  ignore_detachment = true
end

local function onCouplerAttached(node_id, obj2_id, obj2_node_id)
  print(string.format("[KISS_COUPLER] onCouplerAttached veh=%d node=%d to_veh=%d to_node=%d owned=%s ignored=%s",
    obj:getID(), node_id, obj2_id, obj2_node_id, tostring(ownership), tostring(ignore_attachment)))
  if not ownership then return end
  if ignored_couplers[node_id] then return end
  if obj2_id == obj:getID() then return end -- Ignore self-coupling (e.g. fifth wheel hitch without trailer)
  if ignore_attachment then
    ignore_attachment = false
    return
  end
  local node_data = v.data.nodes[node_id]
  local data = {
    obj_a = obj:getID(),
    obj_b = obj2_id,
    node_a_id = node_id,
    node_b_id = obj2_node_id,
    coupler_tag = node_data and node_data.couplerTag or ""
  }
  obj:queueGameEngineLua("vehiclemanager.attach_coupler_inner(\'"..jsonEncode(data).."\')")
end

local function onCouplerDetached(node_id, obj2_id, obj2_node_id)
  print(string.format("[KISS_COUPLER] onCouplerDetached veh=%d node=%d from_veh=%d from_node=%d owned=%s",
    obj:getID(), node_id, obj2_id, obj2_node_id, tostring(ownership)))
  if not ownership then return end
  if ignored_couplers[node_id] then return end
  if obj2_id == obj:getID() then return end -- Ignore self-decoupling
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

M.ignore_coupler_node = ignore_coupler_node
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.kissUpdateOwnership = kissUpdateOwnership
M.attach_coupler = attach_coupler
M.detach_coupler = detach_coupler

return M
