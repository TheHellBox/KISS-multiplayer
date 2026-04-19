-- KissMP cluster-node sync: direct replay of per-node position and velocity.
-- No reconstruction from cluster body twist, no rigid-body assumption. Every
-- DOF (chassis flex, wheel spin, rotor spin, articulation, suspension) is
-- implicitly synced because it's just where each node is and how fast it's moving.

local M = {}

--- Capture current per-node position and velocity for sending to the receiver.
--- Returns two parallel tables keyed by node CID.
local function capture_nodes()
  local positions = {}
  local velocities = {}

  for _, node in pairs(v.data.nodes) do
    local p = obj:getNodePosition(node.cid)
    local v_node = obj:getNodeVelocity(node.cid)
    positions[node.cid] = {p.x, p.y, p.z}
    velocities[node.cid] = {v_node.x, v_node.y, v_node.z}
  end

  return positions, velocities
end

--- Apply authoritative per-node position and velocity on the receiver.
--- Position is written directly. Velocity is realized via a one-physics-step
--- impulse F = m * FPS * (v_target - v_current), which matches the node's
--- velocity to the authoritative value in one integrator step.
local function apply_nodes(positions, velocities)
  if not positions then return end

  for node_id, pos in pairs(positions) do
    if pos and #pos >= 3 then
      obj:setNodePosition(node_id, float3(pos[1], pos[2], pos[3]))
    end
  end

  if not velocities then return end
  local physics_fps = obj:getPhysicsFPS()
  for node_id, vel in pairs(velocities) do
    if vel and #vel >= 3 then
      local current = obj:getNodeVelocity(node_id)
      local m = obj:getNodeMass(node_id)
      local factor = m * physics_fps
      obj:applyForceVector(
        node_id,
        float3(
          (vel[1] - current.x) * factor,
          (vel[2] - current.y) * factor,
          (vel[3] - current.z) * factor
        )
      )
    end
  end
end

M.capture_nodes = capture_nodes
M.apply_nodes = apply_nodes

return M
