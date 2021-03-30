local M = {}

local generation = 0
local timer = 0

M.received_transforms = {}
M.local_transforms = {}
M.raw_positions = {}

M.threshold = 3
M.rot_threshold = 2.5
M.velocity_error_limit = 10

M.hidden = {}

local function update(dt)
  if not network.connection.connected then return end
    -- Get rotation/angular velocity from vehicle lua
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand("kiss_vehicle.update_transform_info()")
    end
  end

  -- Don't apply velocity while paused. If we do, velocity gets stored up and released when the game resumes.
  local apply_velocity = not bullettime.getPause()
  for id, transform in pairs(M.received_transforms) do
    --apply_transform(dt, id, transform, apply_velocity)
    local vehicle = be:getObjectByID(id)
    if vehicle and apply_velocity then
      vehicle:queueLuaCommand("kiss_transforms.update("..dt..")")
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

  local vehicle = be:getObjectByID(id)
  if vehicle then
    transform.time_past = clamp(vehiclemanager.get_current_time() - transform.sent_at, 0, 0.1) * 0.9 + 0.001
    vehicle:queueLuaCommand("kiss_transforms.set_target_transform(\'"..jsonEncode(transform).."\')")
    M.received_transforms[id] = transform
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
