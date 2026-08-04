local M = {}

local generation = 0
local timer = 0

M.raw_transforms = {}
M.received_transforms = {}
M.local_transforms = {}
M.raw_positions = {}
M.inactive = {}
M.teleport_cooldowns = {}

M.threshold = 3
M.rot_threshold = 2.5
M.velocity_error_limit = 10

M.hidden = {}

local DEBUG_GLOBAL = false

-- BeamNG auto-loads lua/vehicle/extensions/*.lua but does not recurse into
-- subfolders. The kiss_mp/* extensions need an explicit addModulePath +
-- loadModulesInDirectory call to become available in vehicle Lua. Prepended
-- to every queueLuaCommand into a kiss_mp/* module so the call is self-healing
-- if the vehicle Lua context ever resets.
local VEHICLE_SYNC_BOOTSTRAP = "extensions.addModulePath('lua/vehicle/extensions/kiss_mp'); extensions.loadModulesInDirectory('lua/vehicle/extensions/kiss_mp'); "

local function queue_kiss_command(vehicle, command)
  if not vehicle then return end
  vehicle:queueLuaCommand(VEHICLE_SYNC_BOOTSTRAP .. command)
end

-- Cluster snap used only for large recovery corrections. The target position
-- passed here must be a refnode/origin position, not COG.
local function apply_cluster_target(vehicle_id,
                                    target_origin_x, target_origin_y, target_origin_z,
                                    target_rotation_x, target_rotation_y, target_rotation_z, target_rotation_w,
                                    target_velocity_x, target_velocity_y, target_velocity_z)
  local veh = be:getObjectByID(vehicle_id)
  if not veh then return end
  local ref_node_id = veh:getRefNodeId()

  local current_rotation = quatFromDir(-veh:getDirectionVector(), veh:getDirectionVectorUp())
  local target_rotation = quat(target_rotation_x, target_rotation_y, target_rotation_z, target_rotation_w)
  local relative_rotation = current_rotation:inversed() * target_rotation

  veh:setClusterPosRelRot(ref_node_id, target_origin_x, target_origin_y, target_origin_z,
    relative_rotation.x, relative_rotation.y, relative_rotation.z, relative_rotation.w)

  local local_velocity = vec3(veh:getVelocity())
  local rotated_local_velocity = local_velocity:rotated(relative_rotation)
  veh:applyClusterVelocityScaleAdd(ref_node_id, 1,
    target_velocity_x - rotated_local_velocity.x,
    target_velocity_y - rotated_local_velocity.y,
    target_velocity_z - rotated_local_velocity.z)
end

local function queue_cog_snap(vehicle, transform)
  local position, rotation = transform.position, transform.rotation
  local velocity = transform.velocity or {0, 0, 0}
  local angular_velocity = transform.angular_velocity or {0, 0, 0}
  if not (position and rotation and #position >= 3 and #rotation >= 4) then return end
  queue_kiss_command(vehicle,
    "kiss_transforms.snap_to_cog_target("
    ..position[1]..","..position[2]..","..position[3]..","
    ..rotation[1]..","..rotation[2]..","..rotation[3]..","..rotation[4]..","
    ..(velocity[1] or 0)..","..(velocity[2] or 0)..","..(velocity[3] or 0)..","
    ..(angular_velocity[1] or 0)..","..(angular_velocity[2] or 0)..","..(angular_velocity[3] or 0)..")"
  )
end

local function update(dt)
  if DEBUG_GLOBAL then
    print("[kisstransform.update] START dt=" .. tostring(dt) .. " received_transforms=" .. tostring(#M.received_transforms))
  end

  if not network.connection.connected then
    if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: not connected") end
    return
  end

  for id, remaining in pairs(M.teleport_cooldowns) do
    remaining = remaining - dt
    if remaining <= 0 then
      M.teleport_cooldowns[id] = nil
    else
      M.teleport_cooldowns[id] = remaining
    end
  end

  -- Refresh each vehicle's local transform cache. Only owned vehicles send
  -- this cache over the network, but remote vehicles still need their vehicle
  -- Lua modules loaded before receiver-side correction runs.
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    local vid = vehicle and vehicle:getID()
    if vehicle and (not M.inactive[vid]) then
      local owned = vehiclemanager.ownership[vid] ~= nil
      queue_kiss_command(vehicle, "kiss_vehicle.update_transform_info(" .. tostring(owned) .. ")")
    end
  end

  -- Don't apply velocity while paused. If we do, velocity gets stored up and released when the game resumes.
  local apply_velocity = not bullettime.getPause()
  if DEBUG_GLOBAL and not apply_velocity then
    print("[kisstransform.update] BLOCKED: game paused (bullettime.getPause()=true)")
  end

  if DEBUG_GLOBAL then
    print("[kisstransform.update] apply_velocity=" .. tostring(apply_velocity) .. " iterating received_transforms...")
  end

  for id, transform in pairs(M.received_transforms) do
    if DEBUG_GLOBAL then
      print("[kisstransform.update] Processing vehicle id=" .. tostring(id))
    end

    local vehicle = be:getObjectByID(id)
    local p = vec3(transform.position)
    local teleport_cooldown = M.teleport_cooldowns[id]

    if not vehicle then
      if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: vehicle " .. tostring(id) .. " not found") end
    elseif teleport_cooldown and teleport_cooldown > 0 then
      if not M.inactive[id] then
        vehicle:setActive(0)
        M.inactive[id] = true
      end
      if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: teleport cooldown for vehicle " .. tostring(id)) end
    elseif not apply_velocity then
      if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: apply_velocity=false for vehicle " .. tostring(id)) end
    elseif vehiclemanager.ownership[id] then
      if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: we own vehicle " .. tostring(id)) end
    else
      if ((p:distance(vec3(getCameraPosition())) > kissui.view_distance[0])) and kissui.enable_view_distance[0] then
        if DEBUG_GLOBAL then
          local dist = p:distance(vec3(getCameraPosition()))
          print("[kisstransform.update] BLOCKED: vehicle " .. tostring(id) .. " outside view distance (dist=" .. dist .. ")")
        end
        if (not M.inactive[id]) then
          vehicle:setActive(0)
          M.inactive[id] = true
        end
      else
        if M.inactive[id] then
          vehicle:setActive(1)
          M.inactive[id] = false
          -- Reactivated replicas can be far from the authority because
          -- setActive(0) freezes local physics. Snap once, then resume the
          -- normal per-frame correction path.
          queue_cog_snap(vehicle, transform)
          if DEBUG_GLOBAL then print("[kisstransform.update] Reactivated vehicle " .. tostring(id)) end
        end
        if DEBUG_GLOBAL then
          print("[kisstransform.update] QUEUING update for vehicle " .. tostring(id))
        end
        -- Per-frame correction runs from kiss_transforms.updateGFX inside
        -- vehicle Lua. GE only handles activity/view-distance state here.
      end
    end
  end

  if DEBUG_GLOBAL then
    print("[kisstransform.update] END")
  end
end

local function update_vehicle_transform(data)
  local transform = data.transform
  transform.owner = data.vehicle_id
  transform.sent_at = data.sent_at
  transform.send_timer = data.send_timer
  transform.ping_ms = data.ping_ms
  transform.receiver_ping_ms = network.connection.rtt_smooth_ms or network.connection.ping or 0

  -- Normalize quaternion in place so all downstream consumers (vehicle-Lua
  -- try_rude predicted-pose comparison, kiss_sync snapshot buffer, and
  -- COG-aware recovery snaps) see a unit quaternion.
  local r = transform.rotation
  if r and #r >= 4 then
    local n = math.sqrt(r[1]*r[1] + r[2]*r[2] + r[3]*r[3] + r[4]*r[4])
    if n > 1e-9 then
      r[1], r[2], r[3], r[4] = r[1]/n, r[2]/n, r[3]/n, r[4]/n
    end
  end

  local id = vehiclemanager.id_map[transform.owner or -1] or -1
  if vehiclemanager.ownership[id] then return end
  M.raw_positions[transform.owner or -1] = transform.position
  M.received_transforms[id] = transform

  local vehicle = be:getObjectByID(id)
  if vehicle and (not M.inactive[id]) then
    -- Packet arrival hands the new authoritative COG pose to kiss_sync.
    -- Application happens per-frame from kiss_transforms.update(dt), not on
    -- packet arrival.
    queue_kiss_command(vehicle, "kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ")")
  end
end

local function push_transform(id, t)
  M.local_transforms[id] = jsonDecode(t)
end

local function set_teleport_cooldown(vehicle_id, duration)
  M.teleport_cooldowns[vehicle_id] = math.max(duration or 0.35, 0)
end

M.send_transform_updates = send_transform_updates
M.send_vehicle_transform = send_vehicle_transform
M.update_vehicle_transform = update_vehicle_transform
M.push_transform = push_transform
M.queue_kiss_command = queue_kiss_command
M.queue_cog_snap = queue_cog_snap
M.set_teleport_cooldown = set_teleport_cooldown
M.apply_cluster_target = apply_cluster_target
M.onUpdate = update

return M
