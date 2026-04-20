-- KissMP cluster-node sync: direct replay of per-node position and velocity.
-- Tier 2: positions are transmitted as quantized body-frame offsets from rest
-- pose. Nodes whose offset quantizes to zero are omitted entirely — chassis at
-- rest costs nothing on the wire. Velocities are quantized world-frame values,
-- sent for every node (we don't reconstruct them from cluster body twist — that
-- was the drift source we escaped from).

local M = {}

-- Quantization factors for i16 wire format. Both chosen to cover typical ranges
-- comfortably while staying within i16 (±32767).
local POSITION_SCALE = 1000    -- 1 unit = 1 mm, range ±32.767 m
local VELOCITY_SCALE = 100     -- 1 unit = 1 cm/s, range ±327.67 m/s
local I16_MIN = -32768
local I16_MAX = 32767

-- Per-cid body-frame rest position, built lazily on first capture/apply.
-- Stored in body frame so it's static regardless of how the vehicle is oriented
-- or positioned in the world; we rotate into world orientation at runtime.
local rest_body_by_cid = nil

local function build_rest_cache()
  if rest_body_by_cid then return end
  rest_body_by_cid = {}
  local inverse_rot = quat(obj:getRotation()):inversed()
  for _, node in pairs(v.data.nodes) do
    rest_body_by_cid[node.cid] = inverse_rot * obj:getNodePosition(node.cid)
  end
end

local function quantize(val, scale)
  local q = math.floor(val * scale + 0.5)
  if q > I16_MAX then return I16_MAX end
  if q < I16_MIN then return I16_MIN end
  return q
end

--- Capture per-node state on the authority side.
--- Positions: body-frame offsets from rest, quantized; zero entries skipped.
--- Velocities: world-frame velocity, quantized; all nodes included.
local function capture_nodes()
  build_rest_cache()
  local positions = {}
  local velocities = {}
  local inverse_rot = quat(obj:getRotation()):inversed()

  for _, node in pairs(v.data.nodes) do
    local cid = node.cid
    local body_pos = inverse_rot * obj:getNodePosition(cid)
    local rest_body = rest_body_by_cid[cid]
    local qx = quantize(body_pos.x - rest_body.x, POSITION_SCALE)
    local qy = quantize(body_pos.y - rest_body.y, POSITION_SCALE)
    local qz = quantize(body_pos.z - rest_body.z, POSITION_SCALE)
    if qx ~= 0 or qy ~= 0 or qz ~= 0 then
      positions[cid] = { qx, qy, qz }
    end

    local vn = obj:getNodeVelocityVector(cid)
    velocities[cid] = {
      quantize(vn.x, VELOCITY_SCALE),
      quantize(vn.y, VELOCITY_SCALE),
      quantize(vn.z, VELOCITY_SCALE),
    }
  end

  return positions, velocities
end

--- Apply authoritative per-node state on the receiver.
--- For each node: reconstruct body-frame position as rest + received offset
--- (or just rest if omitted), rotate into world orientation, setNodePosition.
--- Velocity applied via one-physics-step impulse F = m * FPS * (v_target - v_current).
local function apply_nodes(positions, velocities)
  build_rest_cache()
  local body_rot = quat(obj:getRotation())

  -- Iterate all nodes; those absent from the received map are treated as at rest.
  for cid, rest_body in pairs(rest_body_by_cid) do
    local bx, by, bz = rest_body.x, rest_body.y, rest_body.z
    local entry = positions and (positions[cid] or positions[tostring(cid)])
    if entry and #entry >= 3 then
      bx = bx + entry[1] / POSITION_SCALE
      by = by + entry[2] / POSITION_SCALE
      bz = bz + entry[3] / POSITION_SCALE
    end
    local world = body_rot * vec3(bx, by, bz)
    obj:setNodePosition(cid, float3(world.x, world.y, world.z))
  end

  if not velocities then return end
  local physics_fps = obj:getPhysicsFPS()
  for node_id, vel in pairs(velocities) do
    local cid = tonumber(node_id)
    if cid and vel and #vel >= 3 then
      local tx = vel[1] / VELOCITY_SCALE
      local ty = vel[2] / VELOCITY_SCALE
      local tz = vel[3] / VELOCITY_SCALE
      local current = obj:getNodeVelocityVector(cid)
      local m = obj:getNodeMass(cid)
      local factor = m * physics_fps
      obj:applyForceVector(
        cid,
        float3(
          (tx - current.x) * factor,
          (ty - current.y) * factor,
          (tz - current.z) * factor
        )
      )
    end
  end
end

M.capture_nodes = capture_nodes
M.apply_nodes = apply_nodes

return M
