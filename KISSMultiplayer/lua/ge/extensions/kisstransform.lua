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

-- Grace period after a vehicle loses its coupled_to entry. During this
-- window the vehicle skips full PD sync so a brief detach→re-attach cycle
-- (e.g. vehicle reset) doesn't slam it with ang_force=100 for a few frames
-- and rip the physical coupler before the re-attach event arrives.
local DECOUPLE_GRACE = 3.0
local decouple_timestamps = {}

-- Cluster-aware teleport state. try_rude is disabled for coupled trucks
-- because a per-vehicle teleport rips the hitch apart. Instead, when any
-- member of a coupled cluster drifts beyond CLUSTER_TELEPORT_THRESHOLD, we
-- translate the whole cluster by a single rigid world offset — preserving
-- the current relative pose between members so the coupler constraint
-- isn't disturbed.
local cluster_teleport_cooldowns = {}
local CLUSTER_TELEPORT_THRESHOLD = 8  -- metres
local CLUSTER_TELEPORT_COOLDOWN = 1.5 -- seconds

-- Walk the coupled_to / coupled_trucks graph starting at start_id. Returns
-- a list of all vehicle ids in the same coupled cluster. For a simple
-- truck+trailer pair this is a 2-element list; the graph walk supports
-- road trains (truck + multiple connected trailers) transparently.
local function get_cluster_members(start_id)
  local members = {}
  local visited = {}
  local stack = { start_id }
  while #stack > 0 do
    local id = table.remove(stack)
    if not visited[id] then
      visited[id] = true
      table.insert(members, id)
      local as_trailer = vehiclemanager.coupled_to[id]
      if as_trailer and as_trailer.truck_id then
        table.insert(stack, as_trailer.truck_id)
      end
      local as_truck = vehiclemanager.coupled_trucks and vehiclemanager.coupled_trucks[id]
      if as_truck then
        table.insert(stack, as_truck)
      end
    end
  end
  return members
end

local function cluster_key(members)
  local min_id = math.huge
  for _, id in ipairs(members) do
    if id < min_id then min_id = id end
  end
  return min_id
end

-- Pick the truck member as the rigid-translation reference. Trucks always
-- broadcast VehicleUpdate and have the most reliable transform target.
local function find_truck_in_cluster(members)
  for _, id in ipairs(members) do
    if vehiclemanager.coupled_trucks and vehiclemanager.coupled_trucks[id] then
      return id
    end
  end
  return members[1]
end

-- Rigid-body snap of every cluster member around the truck's current pose:
--   new_pos = pivot_target + rot_delta * (member_pos - pivot_current)
--   new_rot = rot_delta * member_rot
-- This translates AND rotates the whole cluster as a single rigid body,
-- preserving the relative pose between members (so the coupler constraint
-- is not disturbed) while atomically correcting heading error that the
-- per-tick PD can't touch without whip-cracking the hitch.
--
-- Uses setPosRot rather than setPositionNoPhysicsReset because we need to
-- snap rotation too; setPosRot may do a physics reset (velocity cleared,
-- beams settled) but applied uniformly across both cluster members with
-- matching relative pose, the coupler should re-latch immediately on the
-- next physics tick.
local function teleport_cluster(members, pivot_current, pivot_target, rot_delta)
  for _, id in ipairs(members) do
    local v = be:getObjectByID(id)
    if v then
      local cur_pos = vec3(v:getPosition())
      local cur_rot = quat(v:getRefNodeMatrix():toQuatF())
      local offset = cur_pos - pivot_current
      local new_pos = pivot_target + rot_delta * offset
      local new_rot = rot_delta * cur_rot
      v:setPosRot(new_pos.x, new_pos.y, new_pos.z, new_rot.x, new_rot.y, new_rot.z, new_rot.w)
    end
  end
end

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
            vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.set_target_transform(%q, %f) end",
              jsonEncode(transform),
              (kisstuning and kisstuning.values and kisstuning.values.accel_clamp) or 15.0
            ))
            vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.update_coupled(%f, %q) end",
              dt,
              jsonEncode(coupled_data)
            ))
          end
        else
          -- Grace period: a vehicle that just lost its coupled_to entry
          -- (e.g. during a reset detach→re-attach cycle) skips full PD sync
          -- so we don't slam it with ang_force=100 while it's still
          -- physically coupled, which would rip the coupler apart before
          -- the re-attach event arrives.
          local grace_stamp = decouple_timestamps[id]
          if grace_stamp then
            local now_t = vehiclemanager.get_current_time()
            if (now_t - grace_stamp) < DECOUPLE_GRACE then
              vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.set_target_transform(%q, %f) end",
              jsonEncode(transform),
              (kisstuning and kisstuning.values and kisstuning.values.accel_clamp) or 15.0
            ))
              goto continue
            else
              decouple_timestamps[id] = nil
            end
          end

          -- Normal vehicle: full PD sync.
          -- For trucks with a coupled trailer on this client, skip try_rude
          -- (the 6m teleport would yank the whole coupled rig) and scale the
          -- angular correction by the mass-ratio computed at attach time so
          -- heavy trailers get softer angular pushes.
          local trailer_id = vehiclemanager.coupled_trucks and vehiclemanager.coupled_trucks[id]
          local ang_scale = nil
          local truck_mass = vehiclemanager.vehicle_masses and vehiclemanager.vehicle_masses[id]
          if trailer_id then
            local coupling = vehiclemanager.coupled_to[trailer_id]
            if coupling then
              ang_scale = coupling.ang_scale
            end
          end

          -- Cluster-aware emergency teleport: if this vehicle is part of a
          -- coupled rig and drift exceeds the cluster threshold, translate
          -- the whole cluster together by the truck's world offset.
          -- Preserves relative pose so the hitch constraint isn't disturbed.
          local is_clustered = vehiclemanager.coupled_to[id] ~= nil or trailer_id ~= nil
          if is_clustered then
            local cur_pos = vec3(vehicle:getPosition())
            local drift = cur_pos:distance(p)
            if drift > CLUSTER_TELEPORT_THRESHOLD then
              local members = get_cluster_members(id)
              local key = cluster_key(members)
              local now = vehiclemanager.get_current_time()
              local last = cluster_teleport_cooldowns[key]
              if not last or (now - last) > CLUSTER_TELEPORT_COOLDOWN then
                local truck_id = find_truck_in_cluster(members)
                local truck_vehicle = be:getObjectByID(truck_id)
                local truck_transform = M.received_transforms[truck_id]
                if truck_vehicle and truck_transform then
                  local pivot_current = vec3(truck_vehicle:getPosition())
                  local pivot_target  = vec3(truck_transform.position)
                  local truck_cur_rot = quat(truck_vehicle:getRefNodeMatrix():toQuatF())
                  local truck_tgt_rot = quat(truck_transform.rotation)
                  -- rot_delta rotates current truck orientation onto target:
                  --   rot_delta * truck_cur_rot = truck_tgt_rot
                  local rot_delta = truck_tgt_rot * truck_cur_rot:inversed()
                  teleport_cluster(members, pivot_current, pivot_target, rot_delta)
                  cluster_teleport_cooldowns[key] = now
                  print(string.format(
                    "[KISS_CLUSTER] Teleported cluster %d (drift=%.2fm, members=%d)",
                    key, drift, #members
                  ))
                end
              end
            end
          end

          vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.set_target_transform(%q, %f) end",
              jsonEncode(transform),
              (kisstuning and kisstuning.values and kisstuning.values.accel_clamp) or 15.0
            ))
          if ang_scale then
            -- Truck with trailers — needs full PD, no deadband. skip_rude
            -- is true so it takes the coupled-truck branch (lateral force
            -- at front chassis + low-speed yaw torque fallback). Pass the
            -- current tuning values as trailing args so the coupled path
            -- reads live slider state.
            local t = kisstuning and kisstuning.values or {}
            vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.update(%f, true, %f, %s, nil, %f, %f, %f, %f, nil, %f, %f, %f) end",
              dt, ang_scale,
              truck_mass and tostring(truck_mass) or "nil",
              t.Kp_yaw or 1.0,
              t.Kd_yaw or 0.35,
              t.force_cap_accel or 0.6,
              t.speed_gate_high or 5.5,
              t.lateral_pd_scale or 0.2,
              t.speed_gate_low or 1.5,
              t.lateral_integral_gain or 0.5
            ))
          else
            -- Plain uncoupled vehicle — enable the small-delta deadband
            -- so cargo on tilt decks doesn't get continuously jiggled by
            -- PD forces when already near its target. Coupled rigs NEVER
            -- reach this branch (guarded by the outer coupled_to check
            -- and the ang_scale check above).
            local deadband_flag = "true"
            if kisstuning and kisstuning.values and kisstuning.values.deadband_enabled == false then
              deadband_flag = "false"
            end
            if kisstuning and kisstuning.values and kisstuning.values.use_front_puller_solo then
              -- Opt-in: route solo vehicles through the same front-puller
              -- mechanism as coupled trucks. Pass tuning values + own
              -- vehicle mass + trailing use_front_puller_solo=true flag.
              local t = kisstuning.values
              local veh_mass = vehiclemanager.vehicle_masses and vehiclemanager.vehicle_masses[id]
              vehicle:queueLuaCommand(string.format(
                "if kiss_transforms then kiss_transforms.update(%f, false, nil, %s, %s, %f, %f, %f, %f, true, %f, %f, %f) end",
                dt,
                veh_mass and tostring(veh_mass) or "nil",
                deadband_flag,
                t.Kp_yaw or 1.0,
                t.Kd_yaw or 0.35,
                t.force_cap_accel or 0.6,
                t.speed_gate_high or 5.5,
                t.lateral_pd_scale or 0.2,
                t.speed_gate_low or 1.5,
                t.lateral_integral_gain or 0.5
              ))
            else
              -- Legacy path: full angular PD via apply_linear_velocity_ang_torque
              vehicle:queueLuaCommand(string.format(
                "if kiss_transforms then kiss_transforms.update(%f, false, nil, nil, %s) end",
                dt, deadband_flag
              ))
            end
          end
        end
        ::continue::
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
    vehicle:queueLuaCommand(string.format(
              "if kiss_transforms then kiss_transforms.set_target_transform(%q, %f) end",
              jsonEncode(transform),
              (kisstuning and kisstuning.values and kisstuning.values.accel_clamp) or 15.0
            ))
  end
end

local function push_transform(id, t)
  M.local_transforms[id] = jsonDecode(t)
end

local function mark_decoupled(id, timestamp)
  decouple_timestamps[id] = timestamp  -- nil clears
end

M.mark_decoupled = mark_decoupled
M.send_transform_updates = send_transform_updates
M.send_vehicle_transform = send_vehicle_transform
M.update_vehicle_transform = update_vehicle_transform
M.push_transform = push_transform
M.onUpdate = update

return M
