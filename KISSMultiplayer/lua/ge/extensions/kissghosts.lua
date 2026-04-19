local M = {}

M.global_state = {}
M.ghost_state = {}
M.overrides = {}

local actual_ghost_states = {}
local function set_vehicle_ghost(veh_id, ghost_state, mesh_fade, is_global)
  ghost_state = ghost_state or 0
  if M.overrides[veh_id] then
    -- we still want M.ghost_state to keep its original value
    ghost_state = M.overrides[veh_id]
  else
    M.ghost_state[veh_id] = ghost_state
  end

  if is_global then
    M.global_state[veh_id] = ghost_state
  end

  if actual_ghost_states[veh_id] == ghost_state then return end
  actual_ghost_states[veh_id] = ghost_state

  local veh = getObjectByID(veh_id)
  if ghost_state == 0 then -- no ghost
    veh:setActive(1)
    veh:queueLuaCommand("kiss_vehicle.set_collision(true)")
  elseif ghost_state == 1 then -- no collisions
    veh:setActive(1)
    veh:queueLuaCommand("kiss_vehicle.set_collision(false)")
  elseif ghost_state == 2 then -- in stasis (more logic for this state is in onUpdate)
    veh:setActive(1)
    veh:queueLuaCommand("kiss_vehicle.set_collision(false)")
  elseif ghost_state == 3 then -- tucked somewhere in a parallel universe
    veh:setActive(0)
  end

  if mesh_fade ~= nil then
    if type(mesh_fade) ~= "number" then
      mesh_fade = mesh_fade and 0.5 or 1
    end
    veh:setMeshAlpha(mesh_fade, "")
  end
end

local bb_center_a, bb_half_axis0_a, bb_half_axis1_a, bb_half_axis2_a = vec3(), vec3(), vec3(), vec3()
local bb_center_b, bb_half_axis0_b, bb_half_axis1_b, bb_half_axis2_b = vec3(), vec3(), vec3(), vec3()

local function check_overlaps(vid_a)
  bb_center_a:set(be:getObjectOOBBCenterXYZ(vid_a))
  bb_half_axis0_a:set(be:getObjectOOBBHalfAxisXYZ(vid_a, 0))
  bb_half_axis1_a:set(be:getObjectOOBBHalfAxisXYZ(vid_a, 1))
  bb_half_axis2_a:set(be:getObjectOOBBHalfAxisXYZ(vid_a, 2))

  local id_to_owner_map = vehiclemanager.id_to_owner_map
  for vid_b in vehiclesIterator() do
    if vid_a ~= vid_b and id_to_owner_map[vid_a] ~= id_to_owner_map[vid_b] then
      bb_center_b:set(be:getObjectOOBBCenterXYZ(vid_b))
      bb_half_axis0_b:set(be:getObjectOOBBHalfAxisXYZ(vid_b, 0))
      bb_half_axis1_b:set(be:getObjectOOBBHalfAxisXYZ(vid_b, 1))
      bb_half_axis2_b:set(be:getObjectOOBBHalfAxisXYZ(vid_b, 2))

      if overlapsOBB_OBB(bb_center_a, bb_half_axis0_a, bb_half_axis1_a, bb_half_axis2_a,
        bb_center_b, bb_half_axis0_b, bb_half_axis1_b, bb_half_axis2_b) then
        return true
      end
    end
  end

  return false
end

local function set_respawn_override(vid, is_global)
  if check_overlaps(vid) then
    M.overrides[vid] = 1
  else
    M.overrides[vid] = nil
  end

  set_vehicle_ghost(vid, M.ghost_state[vid], M.overrides[vid] ~= nil, is_global)
end

local function set_pause_override(vid, override, is_global)
  if override then
    M.overrides[vid] = 2
  elseif check_overlaps(vid) then
    M.overrides[vid] = 1
  else
    M.overrides[vid] = nil
  end

  set_vehicle_ghost(vid, M.ghost_state[vid], M.overrides[vid] ~= nil, is_global)
end

local velocity = vec3()
local function set_pause_override_for_owned(bool)
  for id in pairs(vehiclemanager.ownership) do
    if bool then
      local vehicle = getObjectByID(id)
      velocity:set(vehicle:getVelocityXYZ())
      if velocity:length() < 1 then
        set_pause_override(id, true, true)
      end
    else
      set_pause_override(id, false, true)
    end
  end
  vehiclemanager.send_vehicle_meta_updates()
end

local function onUpdate()
  for vid, v in pairs(actual_ghost_states) do
    if v == 2 then
      -- 0.75 appears to be a safe value
      -- values too small cause breakage
      local veh = getObjectByID(vid)
      if veh and v then
        veh:applyClusterVelocityScaleAdd(0, 0.75, 0, 0, 0)
      end
    end
  end

  for vid, v in pairs(M.overrides) do
    if v == 1 then
      set_respawn_override(vid, true)
    end
  end
end

local pause_counter = 0
local pause_requests = {}

local function attempt_pause(id)
  if pause_requests[id] then
    return
  end
  pause_requests[id] = true
  pause_counter = pause_counter + 1
  if pause_counter > 0 then
    set_pause_override_for_owned(true)
    SFXSystem.setGlobalParameter("g_GamePause", 1)
  end
end

local function attempt_unpause(id)
  if not pause_requests[id] then
    return
  end
  pause_requests[id] = nil
  pause_counter = math.max(0, pause_counter - 1)

  if pause_counter == 0 then
    set_pause_override_for_owned(false)
    SFXSystem.setGlobalParameter("g_GamePause", 0)
  end
end

local function onVehicleSpawned(veh_id)
  -- because collisions are disabled vehicle side on respawn, this *must* update
  actual_ghost_states[veh_id] = nil

  set_respawn_override(veh_id, true)
end

local function onVehicleResetted(veh_id)
  -- because collisions are disabled vehicle side on respawn, this *must* update
  actual_ghost_states[veh_id] = nil

  set_respawn_override(veh_id, true)
end

local function onVehicleDestroyed(vehId)
  M.global_state[vehId] = nil
  M.ghost_state[vehId] = nil
  M.overrides[vehId] = nil
end

M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleResetted = onVehicleResetted

M.set_vehicle_ghost = set_vehicle_ghost
M.set_pause_override = set_pause_override
M.set_respawn_override = set_respawn_override

M.attempt_pause = attempt_pause
M.attempt_unpause = attempt_unpause

return M