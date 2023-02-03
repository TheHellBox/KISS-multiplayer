local M = {}
local parts_config = v.config
local nodes = {}
local ref_nodes = {}

local last_node = 1
local nodes_per_frame = 32

local node_pos_thresh = 3
local node_pos_thresh_sqr = node_pos_thresh * node_pos_thresh

M.test_quat = quat(0.707, 0, 0, 0.707)

local function onExtensionLoaded()
  local force = obj:getPhysicsFPS()

  local ref = {
    v.data.refNodes[0].left,
    v.data.refNodes[0].up,
    v.data.refNodes[0].back,
    v.data.refNodes[0].ref,
  }

  local total_mass = 0
  local inverse_rot =  quat(obj:getRotation()):inversed()
  for _, node in pairs(v.data.nodes) do
    local node_mass = obj:getNodeMass(node.cid)
    local node_pos = inverse_rot * obj:getNodePosition(node.cid)
    table.insert(
      nodes,
      {
        node.cid,
        node_mass * force,
        true,
        node_pos
      }
    )
    --M.test_nodes_sync[node.cid] = vec3(obj:getNodePosition(node.cid))
    total_mass = total_mass + node_mass
  end

  for _, node in pairs(ref) do
    table.insert(
      ref_nodes,
      {
        node,
        total_mass * force / 4,
        true,
        inverse_rot * obj:getNodePosition(node)
      }
    )
  end
end

  -- NOTE:
  -- This is a temperary solution. It's not great. We made it to release the mod.
  -- A better solution will be used in future versions
local function update_eligible_nodes()
  local inverse_rot =  quat(obj:getRotation()):inversed()
  for k=last_node, math.min(#nodes , last_node + nodes_per_frame) do
    local node = nodes[k]
    local local_node_pos = inverse_rot * obj:getNodePosition(node[1])
    local local_original_pos = node[4]
    node[3] = (local_node_pos - local_original_pos):squaredLength() < node_pos_thresh_sqr
    last_node = k
  end
  if last_node == #nodes then last_node = 1 end
end

local function update_transform_info()
  local r = quat(obj:getRotation())
  local p = obj:getPosition()
  
  local throttle_input = electrics.values.throttle_input or 0
  local brake_input = electrics.values.brake_input or 0
  if electrics.values.gearboxMode == "arcade" and electrics.values.gearIndex < 0 then
    throttle_input, brake_input = brake_input, throttle_input
  end
  
  local input = {
    vehicle_id = obj:getID() or 0,
    throttle_input = throttle_input,
    brake_input =  brake_input,
    clutch = electrics.values.clutch_input or 0,
    parkingbrake = electrics.values.parkingbrake_input or 0,
    steering_input = electrics.values.steering_input or 0,
  }
  local gearbox = kiss_gearbox.get_gearbox_data()
  local transform = {
    position  = {p.x, p.y, p.z},
    rotation  = {r.x, r.y, r.z, r.w},
    input = input,
    gearbox = gearbox,
    vel_pitch = obj:getPitchAngularVelocity(),
    vel_roll  = obj:getRollAngularVelocity(),
    vel_yaw   = obj:getYawAngularVelocity(),
  }
  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", \'"..jsonEncode(transform).."\')")
end

local function apply_linear_velocity(x, y, z)
  local velocity = vec3(x, y, z)
  local force = float3(0, 0, 0)
  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      local result = velocity * node[2]
      force:set(result.x, result.y, result.z)
      obj:applyForceVector(node[1], force)
    end
  end
end

local function apply_linear_velocity_ang_torque(x, y, z, pitch, roll, yaw)
  local velocity = vec3(x, y, z)
  local nodes = nodes
  -- 0.1 seems like the safe value we can use for low velocities
  -- NOTE: Doesn't work as well as expected
  if velocity:length() < 0.01 then
    --nodes = ref_nodes
  end
  local rot = vec3(pitch, roll, yaw):rotated(quat(obj:getRotation()))
  local node_position = vec3()
  local force = float3(0, 0, 0)
  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      node_position:set(obj:getNodePosition(node[1]))
      local result = (velocity + node_position:cross(rot)) * node[2]
      force:set(result.x, result.y, result.z)
      obj:applyForceVector(node[1], force)
    end
  end
end

local function send_vehicle_config()
  local config = v.config
  local r = quat(obj:getRotation())
  local p = obj:getPosition()
  local data = {
    position = {p.x, p.y, p.z},
    rotation = {r.x, r.y, r.z, r.w},
  }
  obj:queueGameEngineLua("vehiclemanager.send_vehicle_config_inner("..obj:getID()..", \'"..jsonEncode(config).."\', \'"..jsonEncode(data).."\')")
end

M.update_transform_info = update_transform_info
M.apply_linear_velocity_ang_torque = apply_linear_velocity_ang_torque
M.update_eligible_nodes = update_eligible_nodes
M.apply_linear_velocity = apply_linear_velocity
M.onExtensionLoaded = onExtensionLoaded
M.set_reference = set_reference
M.save_state = save_state
M.send_vehicle_config = send_vehicle_config
return M
