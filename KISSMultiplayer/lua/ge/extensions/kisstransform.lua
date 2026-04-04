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

        local truck_id = vehiclemanager.coupled_to[id]
        if truck_id then
          -- Red sphere above = this vehicle is in coupled_to
          local cpos = vehicle:getPosition()
          debugDrawer:drawSphere(vec3(cpos.x, cpos.y, cpos.z + 3):toPoint3F(), 0.5, ColorF(1, 0, 0, 0.8))
          -- Coupled vehicle (trailer): relative-angle sync only
          local truck = be:getObjectByID(truck_id)
          local truck_transform = M.received_transforms[truck_id]
          if truck and truck_transform and truck_transform.rotation then
            local truck_rot_local = truck:getRotation()
            vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ") end")
            vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.update_coupled(%f, %q, %q) end",
              dt,
              jsonEncode(truck_transform.rotation),
              jsonEncode({truck_rot_local.x, truck_rot_local.y, truck_rot_local.z, truck_rot_local.w})
            ))
          end
        else
          -- Normal vehicle: full PD sync
          vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ") end")
          vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.update("..dt..") end")
        end
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
    vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ") end")
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
