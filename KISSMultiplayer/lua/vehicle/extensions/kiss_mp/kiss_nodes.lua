-- KissMP Node Sync Module - Phase 1c: Deformation sync
-- Direct state replay for node positions
-- No velocity prediction needed - just apply authoritative positions

local M = {}

--- Capture current node positions for sending to authority
--- Returns table of node positions indexed by node ID
---
--- @return table<number, [f32, f32, f32]> Node positions: { [node_id] = {x, y, z} }
local function capture_nodes()
  local nodes_data = {}

  for _, node in pairs(v.data.nodes) do
    local pos = obj:getNodePosition(node.cid)
    -- Store as [x, y, z] array
    nodes_data[node.cid] = {pos.x, pos.y, pos.z}
  end

  return nodes_data
end

--- Apply node positions from authoritative snapshot
--- Direct state replay - no prediction, no blending for Phase 1c
--- BeamNG's physics solver handles intermediate dynamics locally
---
--- @param nodes_data table<number, [f32, f32, f32]> Node positions from authority
local function apply_nodes(nodes_data)
  if not nodes_data then return end

  for node_id, pos in pairs(nodes_data) do
    if pos and #pos >= 3 then
      obj:setNodePosition(node_id, float3(pos[1], pos[2], pos[3]))
    end
  end
end

--- Export public API
M.capture_nodes = capture_nodes
M.apply_nodes = apply_nodes

return M
