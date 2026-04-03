local M = {}

local string_buffer = require("string.buffer")

M.raw_transforms = {}
M.received_transforms = {}
M.local_transforms = {}
M.raw_positions = {}
M.inactive = {}

M.threshold = 3
M.rot_threshold = 2.5
M.velocity_error_limit = 10

M.hidden = {}

local transform_pos = vec3()
local camera_pos = vec3()
local function update(dt)
  if not network.connection.connected then return end
  -- Get rotation/angular velocity from vehicle lua
  for vid, v in vehiclesIterator() do
    if not M.inactive[vid] then
      v:queueLuaCommand("kiss_vehicle.update_transform_info()")
    end
  end

  -- Don't apply velocity while paused. If we do, velocity gets stored up and released when the game resumes.
  local apply_velocity = not bullettime.getPause()
  camera_pos:set(core_camera.getPositionXYZ())
  local view_distance = kissui.enable_view_distance[0] and kissui.view_distance[0] * kissui.view_distance[0] or nil
  for id, transform in pairs(M.received_transforms) do
    --apply_transform(dt, id, transform, apply_velocity)
    local vehicle = getObjectByID(id)
    transform_pos:set(transform.position[1], transform.position[2], transform.position[3])
    if vehicle and apply_velocity and (not vehiclemanager.ownership[id]) then
      if view_distance and (transform_pos:squaredDistance(camera_pos) > view_distance) then
        if not M.inactive[id] then
          vehicle:setActive(0)
          M.inactive[id] = true
        end
      else
        if M.inactive[id] then
          vehicle:setActive(1)
          M.inactive[id] = false
        end
        vehicle:queueLuaCommand(string.format(
          "kiss_transforms.update(%f)",
          dt))
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

  local vehicle = getObjectByID(id)
  transform.time_past = clamp(vehiclemanager.get_current_time() - transform.sent_at, 0, 0.1) * 0.9 + 0.001
  if vehicle and (not M.inactive[id]) then
    vehicle:queueLuaCommand(string.format(
      "kiss_transforms.set_target_transform(%q)",
      string_buffer.encode(transform)))
  end
end

local function push_transform(id, t)
  M.local_transforms[id] = string_buffer.decode(t)
end

M.update_vehicle_transform = update_vehicle_transform
M.push_transform = push_transform
M.onUpdate = update

return M
