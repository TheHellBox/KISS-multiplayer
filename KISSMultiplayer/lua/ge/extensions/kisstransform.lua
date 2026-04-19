local M = {}

local generation = 0
local timer = 0

M.raw_transforms = {}
M.received_transforms = {}
M.local_transforms = {}
M.raw_positions = {}
M.inactive = {}

M.threshold = 3
M.rot_threshold = 2.5
M.velocity_error_limit = 10

M.hidden = {}

local DEBUG_GLOBAL = true  -- Debug logging for global manager
local function update(dt)
  if DEBUG_GLOBAL then
    print("[kisstransform.update] START dt=" .. tostring(dt) .. " received_transforms=" .. tostring(#M.received_transforms))
  end

  if not network.connection.connected then
    if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: not connected") end
    return
  end

  -- Get rotation/angular velocity from vehicle lua
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle and (not M.inactive[vehicle:getID()]) then
      vehicle:queueLuaCommand("kiss_vehicle.update_transform_info()")
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

    --apply_transform(dt, id, transform, apply_velocity)
    local vehicle = be:getObjectByID(id)
    local p = vec3(transform.position)

    if not vehicle then
      if DEBUG_GLOBAL then print("[kisstransform.update] BLOCKED: vehicle " .. tostring(id) .. " not found") end
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
          if DEBUG_GLOBAL then print("[kisstransform.update] Reactivated vehicle " .. tostring(id)) end
        end
        if DEBUG_GLOBAL then
          print("[kisstransform.update] QUEUING commands for vehicle " .. tostring(id))
        end
        vehicle:queueLuaCommand("kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ")")
        vehicle:queueLuaCommand("kiss_transforms.update("..dt..")")
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

  local id = vehiclemanager.id_map[transform.owner or -1] or -1
  if vehiclemanager.ownership[id] then return end
  M.raw_positions[transform.owner or -1] = transform.position
  M.received_transforms[id] = transform

  local vehicle = be:getObjectByID(id)
  if vehicle and (not M.inactive[id]) then
    transform.time_past = clamp(vehiclemanager.get_current_time() - transform.sent_at, 0, 0.1) * 0.9 + 0.001
    transform.cluster_nodes = data.cluster_nodes
    vehicle:queueLuaCommand("kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ")")
  end
end

local function push_transform(id, t)
  M.local_transforms[id] = jsonDecode(t)
end

M.send_transform_updates = send_transform_updates
M.send_vehicle_transform = send_vehicle_transform
M.update_vehicle_transform = update_vehicle_transform
M.push_transform = push_transform
M.onUpdate = update

return M
