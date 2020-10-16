local M = {}

local function send()
  local nodes_table = {
    vehicle_id = obj:getID(),
    nodes = {}
  }
  for k, node in pairs(v.data.nodes) do
    local position = obj:getNodePosition(node.cid)
    table.insert(nodes_table.nodes, {position.x, position.y, position.z})
  end
  obj:queueGameEngineLua("network.send_messagepack(4, false, \'"..jsonEncode(nodes_table).."\')")
end

local function apply(nodes)
  local nodes = jsonDecode(nodes)
  for node, pos in pairs(nodes) do
    node = tonumber(node)
    obj:setNodePosition(node, float3(pos[1], pos[2], pos[3]))
    local beam = v.data.beams[node]
    local beamPrecompression = beam.beamPrecompression or 1
    local deformLimit = type(beam.deformLimit) == 'number' and beam.deformLimit or math.huge
    obj:setBeam(-1, beam.id1, beam.id2, beam.beamStrength, beam.beamSpring,
                beam.beamDamp, type(beam.dampCutoffHz) == 'number' and beam.dampCutoffHz or 0,
                beam.beamDeform, deformLimit, type(beam.deformLimitExpansion) == 'number' and beam.deformLimitExpansion or deformLimit,
                beamPrecompression
    )
  end
end

M.send = send
M.apply = apply

return M
