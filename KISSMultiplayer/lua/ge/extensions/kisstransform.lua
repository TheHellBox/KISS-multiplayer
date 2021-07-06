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

local function update(dt)
  if not network.connection.connected then return end
    -- Get rotation/angular velocity from vehicle lua
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle and (not M.inactive[vehicle:getID()]) then
      vehicle:queueLuaCommand("kiss_vehicle.update_transform_info()")
    end
  end

  -- Don't apply velocity while paused. If we do, velocity gets stored up and released when the game resumes.
  local apply_velocity = not bullettime.getPause()
  for id, transform in pairs(M.received_transforms) do
    --apply_transform(dt, id, transform, apply_velocity)
    local vehicle = be:getObjectByID(id)
    local p = vec3(transform.position)
    if vehicle and apply_velocity and (not vehiclemanager.ownership[id]) then
      if ((p:distance(vec3(getCameraPosition())) > kissui.view_distance[0])) and kissui.enable_view_distance[0] then
        if (not M.inactive[id]) then
          vehicle:setActive(0)
          M.inactive[id] = true
        end
      else
        if M.inactive[id] then
          vehicle:setActive(1)
          M.inactive[id] = false
        end
        vehicle:queueLuaCommand("kiss_transforms.set_target_transform(\'"..jsonEncode(transform).."\')")
        vehicle:queueLuaCommand("kiss_transforms.update("..dt..")")
      end
    end
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
    vehicle:queueLuaCommand("kiss_transforms.set_target_transform(\'"..jsonEncode(transform).."\')")
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
