local M = {}

local nodes = {}
local node_by_cid = {}
local connected_node_states = {}
local connected_node_set = {}
local connected_graph = {}
local parent_node = nil
local last_damage = 0

M.mass_cog_body = vec3(0, 0, 0)

local last_cog_compute_time = -math.huge
local COG_RECOMPUTE_INTERVAL_S = 0.2

local SEND_SMOOTH_RATE = 50.0
local smoothed_send_vel = nil
local smoothed_send_omega_body = nil
local last_motion_sample_time = nil
local last_motion_sample_dt = 1/60
local cached_transform_sample = nil
local send_timer = 0

local function get_body_gyro_local_omega()
  return vec3(
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity(),
    obj:getYawAngularVelocity()
  )
end

local function lowpass_dt(prev, target, dt, rate)
  if not prev then
    return vec3(target.x, target.y, target.z)
  end
  local alpha = math.min(rate * dt, 1.0)
  return vec3(
    prev.x + (target.x - prev.x) * alpha,
    prev.y + (target.y - prev.y) * alpha,
    prev.z + (target.z - prev.z) * alpha
  )
end

local function reset_send_smoothers()
  smoothed_send_vel = nil
  smoothed_send_omega_body = nil
  last_motion_sample_time = nil
  last_motion_sample_dt = 1/60
  cached_transform_sample = nil
end

local function get_refnode_ids()
  local refs = v and v.data and v.data.refNodes
  if type(refs) ~= "table" then return {} end
  local entry = refs[0] or refs[1] or refs
  return {
    entry and (entry.ref or entry.idRef or entry.cidRef),
    entry and (entry.back or entry.idX or entry.cidX),
    entry and (entry.up or entry.idY or entry.cidY),
    entry and (entry.left or entry.idLeft or entry.cidLeft),
  }
end

local function resolve_cid(value)
  if type(value) == "number" and node_by_cid[value] then return value end
  if type(value) == "string" then
    local numeric = tonumber(value)
    if numeric and node_by_cid[numeric] then return numeric end
    if beamstate and beamstate.nodeNameMap then
      local mapped = beamstate.nodeNameMap[value]
      if mapped and node_by_cid[mapped] then return mapped end
    end
  end
  return nil
end

local function build_connected_graph()
  connected_graph = {}
  if not (v and v.data and v.data.beams) then return end

  for _, beam in pairs(v.data.beams) do
    if beam.beamType ~= 3 and beam.beamType ~= 4 and beam.beamType ~= 7 then
      local a = resolve_cid(beam.id1)
      local b = resolve_cid(beam.id2)
      if a and b then
        connected_graph[a] = connected_graph[a] or {}
        connected_graph[b] = connected_graph[b] or {}
        connected_graph[a][#connected_graph[a] + 1] = {cid = b, beam = beam.cid}
        connected_graph[b][#connected_graph[b] + 1] = {cid = a, beam = beam.cid}
      end
    end
  end
end

local function choose_parent_node()
  parent_node = nil
  for _, ref in ipairs(get_refnode_ids()) do
    local cid = resolve_cid(ref)
    if cid and connected_graph[cid] then
      parent_node = cid
      return
    end
  end
  for cid in pairs(node_by_cid) do
    parent_node = cid
    return
  end
end

local function rebuild_connected_nodes()
  connected_node_states = {}
  connected_node_set = {}
  if not parent_node then
    for _, state in ipairs(nodes) do
      connected_node_states[#connected_node_states + 1] = state
      connected_node_set[state.cid] = true
    end
    return
  end

  local stack = {parent_node}
  connected_node_set[parent_node] = true
  while #stack > 0 do
    local cid = stack[#stack]
    stack[#stack] = nil
    local state = node_by_cid[cid]
    if state then
      connected_node_states[#connected_node_states + 1] = state
    end
    for _, edge in ipairs(connected_graph[cid] or {}) do
      local other = edge.cid
      if not connected_node_set[other] then
        local broken = edge.beam ~= nil and obj:beamIsBroken(edge.beam)
        if not broken then
          connected_node_set[other] = true
          stack[#stack + 1] = other
        end
      end
    end
  end
end

-- Mass-weighted COG offset in body frame. The receiver uses this same body
-- offset to run the correction loop in COG-space instead of refnode-space.
local function compute_mass_cog_body()
  local total_mass = 0
  local cog_sum_x, cog_sum_y, cog_sum_z = 0, 0, 0

  local cog_nodes = (#connected_node_states > 0) and connected_node_states or nodes
  for _, state in ipairs(cog_nodes) do
    local mass = state.mass or 0
    if mass > 0 then
      local pos = obj:getNodePosition(state.cid)
      if pos then
        cog_sum_x = cog_sum_x + pos.x * mass
        cog_sum_y = cog_sum_y + pos.y * mass
        cog_sum_z = cog_sum_z + pos.z * mass
        total_mass = total_mass + mass
      end
    end
  end

  if total_mass < 1e-9 then
    M.mass_cog_body = vec3(0, 0, 0)
    return
  end

  local inv = 1 / total_mass
  local cog_world = vec3(cog_sum_x * inv, cog_sum_y * inv, cog_sum_z * inv)
  local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  M.mass_cog_body = cog_world:rotated(rot:inversed())
end

local function maybe_recompute_mass_cog_body()
  local now = os.clock()
  local damage = (beamstate and beamstate.damage) or 0
  if damage ~= last_damage then
    rebuild_connected_nodes()
    last_damage = damage
    last_cog_compute_time = -math.huge
  end
  if now - last_cog_compute_time >= COG_RECOMPUTE_INTERVAL_S then
    compute_mass_cog_body()
    last_cog_compute_time = now
  end
end

local function get_mass_cog_body()
  return M.mass_cog_body or vec3(0, 0, 0)
end

local function get_disconnected_node_states()
  local out = {}
  for _, state in ipairs(nodes) do
    if not connected_node_set[state.cid] then
      out[#out + 1] = state
    end
  end
  return out
end

local function update_motion_sample(dt)
  -- BeamMP smooths local velocity from the physics hook, then packet packing
  -- reads that smoothed state. Keep the same semantic split here: physics
  -- samples update the cached motion state, GE-side send code only packages it.
  local now = obj:getSimTime() or os.clock()
  if last_motion_sample_time ~= nil and now <= last_motion_sample_time then
    return
  end

  local sample_dt = dt
  if not sample_dt or sample_dt <= 0 then
    sample_dt = last_motion_sample_time and (now - last_motion_sample_time) or (1/60)
  end
  if sample_dt <= 0 then sample_dt = 1/60 end
  if sample_dt > 0.1 then sample_dt = 0.1 end

  local r = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local p = vec3(obj:getPosition())
  local raw_vel = vec3(obj:getVelocity())
  local raw_omega_body = get_body_gyro_local_omega()

  smoothed_send_vel = lowpass_dt(smoothed_send_vel, raw_vel, sample_dt, SEND_SMOOTH_RATE)
  smoothed_send_omega_body = lowpass_dt(smoothed_send_omega_body, raw_omega_body, sample_dt, SEND_SMOOTH_RATE)

  local v_world = smoothed_send_vel
  local omega_world = smoothed_send_omega_body:rotated(r)

  maybe_recompute_mass_cog_body()
  local cog_world = get_mass_cog_body():rotated(r)
  local p_cog = p + cog_world
  local v_cog = v_world + cog_world:cross(omega_world)

  last_motion_sample_time = now
  last_motion_sample_dt = sample_dt
  send_timer = now
  cached_transform_sample = {
    position = p_cog,
    rotation = r,
    velocity = v_cog,
    angular_velocity = omega_world,
  }
end

local function onExtensionLoaded()
  nodes = {}
  node_by_cid = {}
  connected_node_states = {}
  connected_node_set = {}
  parent_node = nil
  last_damage = (beamstate and beamstate.damage) or 0
  last_cog_compute_time = -math.huge
  reset_send_smoothers()
  send_timer = 0

  if v and v.data and v.data.nodes then
    for _, node in pairs(v.data.nodes) do
      if node.cid ~= nil then
        local state = {
          cid = node.cid,
          mass = obj:getNodeMass(node.cid),
        }
        nodes[#nodes + 1] = state
        node_by_cid[node.cid] = state
      end
    end
  end

  build_connected_graph()
  choose_parent_node()
  rebuild_connected_nodes()
  compute_mass_cog_body()
end

local function onReset()
  last_cog_compute_time = -math.huge
  last_damage = (beamstate and beamstate.damage) or 0
  rebuild_connected_nodes()
  reset_send_smoothers()
  compute_mass_cog_body()
end

local function update_transform_info(_we_own_this_vehicle)
  update_motion_sample()
  local sample = cached_transform_sample
  if not sample then return end

  local throttle_input = electrics.values.throttle_input or 0
  local brake_input = electrics.values.brake_input or 0
  if electrics.values.gearboxMode == "arcade" and electrics.values.gearIndex < 0 then
    throttle_input, brake_input = brake_input, throttle_input
  end

  local input = {
    vehicle_id = obj:getID() or 0,
    throttle_input = throttle_input,
    brake_input = brake_input,
    clutch = electrics.values.clutch_input or 0,
    parkingbrake = electrics.values.parkingbrake_input or 0,
    steering_input = electrics.values.steering_input or 0,
  }
  local transform = {
    position = {sample.position.x, sample.position.y, sample.position.z},
    rotation = {sample.rotation.x, sample.rotation.y, sample.rotation.z, sample.rotation.w},
    velocity = {sample.velocity.x, sample.velocity.y, sample.velocity.z},
    angular_velocity = {sample.angular_velocity.x, sample.angular_velocity.y, sample.angular_velocity.z},
    input = input,
    gearbox = kiss_gearbox.get_gearbox_data(),
    send_timer = send_timer,
    send_dt = last_motion_sample_dt,
  }
  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", " .. string.format("%q", jsonEncode(transform)) .. ")")
end

local function send_vehicle_config()
  local r = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local p = obj:getPosition()
  local data = {
    position = {p.x, p.y, p.z},
    rotation = {r.x, r.y, r.z, r.w},
  }
  obj:queueGameEngineLua("vehiclemanager.send_vehicle_config_inner("..obj:getID()..", " .. string.format("%q", jsonEncode(v.config)) .. ", " .. string.format("%q", jsonEncode(data)) .. ")")
end

M.update_transform_info = update_transform_info
M.onPhysicsStep = update_motion_sample
M.get_mass_cog_body = get_mass_cog_body
M.get_disconnected_node_states = get_disconnected_node_states
M.maybe_recompute_mass_cog_body = maybe_recompute_mass_cog_body
M.compute_mass_cog_body = compute_mass_cog_body
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.send_vehicle_config = send_vehicle_config

return M
