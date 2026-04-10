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

        local coupling = vehiclemanager.coupled_to[id]
        if coupling then
          local truck_id = coupling.truck_id
          -- Coupled vehicle (trailer): constraint-preserving sync
          local truck = be:getObjectByID(truck_id)
          local truck_transform = M.received_transforms[truck_id]
          if truck and truck_transform then
            local truck_pos = vec3(truck:getPosition())
            local truck_rot = quat(truck:getRotation())
            -- Use cached offset vectors from attach time (local space, full 3D)
            local truck_offset = vec3(coupling.truck_offset[1], coupling.truck_offset[2], coupling.truck_offset[3])
            local trailer_offset = vec3(coupling.trailer_offset[1], coupling.trailer_offset[2], coupling.trailer_offset[3])
            local coupled_data

            if coupling.hitch_type == "fifthwheel" then
              -- FIFTH WHEEL PATH: 1 DOF (yaw only)
              -- Compute target articulation angle from network rotations
              local net_truck_rot = quat(truck_transform.rotation)
              local net_trailer_rot = quat(transform.rotation)
              local net_truck_fwd = net_truck_rot * vec3(0, 1, 0)
              local net_trailer_fwd = net_trailer_rot * vec3(0, 1, 0)
              local net_truck_yaw = math.atan2(net_truck_fwd.x, net_truck_fwd.y)
              local net_trailer_yaw = math.atan2(net_trailer_fwd.x, net_trailer_fwd.y)
              local target_artic = net_trailer_yaw - net_truck_yaw
              target_artic = math.atan2(math.sin(target_artic), math.cos(target_artic))

              -- Kingpin world pos: truck full rotation * full 3D truck offset
              local kingpin_world = truck_pos + truck_rot * truck_offset

              -- Expected trailer heading: yaw only — clamp pitch/roll to zero
              local truck_fwd = truck_rot * vec3(0, 1, 0)
              local truck_yaw = math.atan2(truck_fwd.x, truck_fwd.y)
              local expected_trailer_yaw = truck_yaw + target_artic
              local expected_trailer_rot = quatFromEuler(0, 0, expected_trailer_yaw)

              -- Expected trailer CG: kingpin minus yaw-rotated full 3D trailer offset
              local expected_pos = kingpin_world - expected_trailer_rot * trailer_offset

              coupled_data = {
                expected_pos = {expected_pos.x, expected_pos.y, expected_pos.z},
                hitch_type = "fifthwheel",
                target_artic = target_artic,
                kingpin_world = {kingpin_world.x, kingpin_world.y, kingpin_world.z},
              }
            else
              -- BALL HITCH / PINTLE PATH: 3 DOF (full quaternion)
              -- Compute target relative rotation from network rotations
              local net_truck_rot = quat(truck_transform.rotation)
              local net_trailer_rot = quat(transform.rotation)
              local target_rel_rot = net_truck_rot:inversed() * net_trailer_rot

              -- Hitch point world pos: full 3D offset with full truck rotation
              local hitch_world = truck_pos + truck_rot * truck_offset

              -- Expected trailer world rotation = truck rotation * relative rotation
              local expected_trailer_rot = truck_rot * target_rel_rot

              -- Expected trailer CG: hitch point minus full-rotated full 3D trailer offset
              local expected_pos = hitch_world - expected_trailer_rot * trailer_offset

              coupled_data = {
                expected_pos = {expected_pos.x, expected_pos.y, expected_pos.z},
                hitch_type = coupling.hitch_type,  -- "ball" or "pintle"
                target_rel_rot = {target_rel_rot.x, target_rel_rot.y, target_rel_rot.z, target_rel_rot.w},
                kingpin_world = {hitch_world.x, hitch_world.y, hitch_world.z},
              }
            end

            -- Pass expected position to vehicle-side for drift detection
            vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ") end")
            vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.update_coupled(%f, %q) end",
              dt,
              jsonEncode(coupled_data)
            ))
          end
        else
          -- Normal vehicle: full PD sync.
          -- For trucks with a coupled trailer on this client, skip try_rude
          -- (the 6m teleport would yank the whole coupled rig) and scale the
          -- angular correction by the mass-ratio computed at attach time so
          -- heavy trailers get softer angular pushes.
          local trailer_id = vehiclemanager.coupled_trucks and vehiclemanager.coupled_trucks[id]
          local ang_scale = nil
          if trailer_id then
            local coupling = vehiclemanager.coupled_to[trailer_id]
            if coupling then ang_scale = coupling.ang_scale end
          end
          vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.set_target_transform(" .. string.format("%q", jsonEncode(transform)) .. ") end")
          if ang_scale then
            vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.update(%f, true, %f) end",
              dt, ang_scale
            ))
          else
            vehicle:queueLuaCommand("if kiss_transforms then kiss_transforms.update("..dt..") end")
          end
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
