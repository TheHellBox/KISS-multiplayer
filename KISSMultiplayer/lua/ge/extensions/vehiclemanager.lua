local M = {}

local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

local timer = 0
local generation = 0
local meta_timer = 0
local colors_buffer = {}
local plates_buffer = {}
local first_vehicle = true

M.loading_map = false
M.id_map = {}
M.server_ids = {}
M.ownership = {}
M.vehicle_updates_buffer = {}
M.packet_gen_buffer = {}
M.is_network_session = false
M.delay_spawns = false
M.vehicle_buffer = {}
M.coupled_to = {} -- local_game_id (trailer) → local_game_id (truck)
M.coupled_trucks = {} -- local_game_id (truck) → local_game_id (trailer). Inverse index so kisstransform.update can skip try_rude for coupled trucks.
M.known_couplings = {} -- local_game_id → {[node_id] = {obj2id, obj2nodeId}, ...}

-- Forward declaration so any closure defined later that references classify_hitch
-- resolves it as a local upvalue rather than falling through to global lookup.
local classify_hitch

local function get_current_time()
  local date = os.date("*t", os.time() + network.connection.time_offset)
  date.sec = 0
  date.min = 0
  return (network.socket.gettime() + network.connection.time_offset  - os.time(date))
end

local function enable_spawning(enabled)
  local jsCommand = 'angular.element(document.body).injector().get("VehicleSelectConfig").configs.default.hide = {"spawnNew":' .. tostring(not enabled) .. '}'
  be:executeJS(jsCommand)
end

local function color_to_table(color, metal_data)
  return {color.x, color.y, color.z, color.w, metal_data.metallic, metal_data.roughness, metal_data.clearcoat, metal_data.clearcoatRoughness}
end

local function table_to_color(t)
  return {baseColor = {t[1], t[2], t[3], t[4]}, metallic = t[5], roughness = t[6], clearcoat = t[7], clearcoatRoughness = t[8]}
end

local function table_to_paint(t)
  return createVehiclePaint({x=t[1], y=t[2], z=t[3], w=t[4]}, {t[5], t[6], t[7], t[8]})
end

local function color_eq(a, b)
  local color_eq = (a[1] == b[1]) and (a[2] == b[2]) and (a[3] == b[3]) and (a[4] == b[4])
  local metal_eq = (a[5] == b[5]) and (a[6] == b[6]) and (a[7] == b[7]) and (a[8] == b[8])
  return color_eq and metal_eq
end

local function colors_eq(a, b)
  return color_eq(a[1], b[1]) and color_eq(a[2], b[2]) and color_eq(a[3], b[3])
end

local function send_vehicle_update(obj)
  if not kisstransform.local_transforms[obj:getID()] then return end
  local t = kisstransform.local_transforms[obj:getID()]
  if not t.input then return end
  if not t.gearbox then return end
  local rotation = t.rotation
  if obj:getJBeamFilename() == "unicycle" then
    local q = quat(getCameraQuat()):toEulerYXZ()
    local q = quatFromEuler(0.0, 0.0, q.x)
    rotation = {q.x, q.y, q.z, q.w}
  end
  local position = obj:getPosition()
  local velocity = obj:getVelocity()
  local result = {
    transform = {
      position = {position.x, position.y, position.z},
      rotation = rotation,
      velocity = {velocity.x, velocity.y, velocity.z},
      angular_velocity = {t.vel_pitch, t.vel_roll, t.vel_yaw}
    },
    electrics = t.input,
    gearbox = t.gearbox,
    vehicle_id = obj:getID(),
    generation = generation,
    sent_at = get_current_time()
  }
  generation = generation + 1
  network.send_data(
    {
      VehicleUpdate = result
    },
    false
  )
end

local function send_vehicle_meta_updates()
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      local changed = false
      local id = vehicle:getID()
      
      local metal_data = vehicle:getMetallicPaintData()
      local color = vehicle.color
      local palete_0 = vehicle.colorPalette0
      local palete_1 = vehicle.colorPalette1
      local plate = vehicle.licenseText
      local colors = {
        color_to_table(color, metal_data[1]),
        color_to_table(palete_0, metal_data[2]),
        color_to_table(palete_1, metal_data[3])
      }
      
      if plates_buffer[id] then
        changed = changed or plates_buffer[id] ~= plate
      end
      plates_buffer[id] = plate
      
      if colors_buffer[id] then
        changed = changed or not colors_eq(colors, colors_buffer[id])
      end
      colors_buffer[id] = colors
      
      if changed then
        local data = {
          VehicleMetaUpdate = {
            id,
            plate,
            colors
          }
        }
        network.send_data(data, true)
      end
    end
  end
end

local function update_ownership_limits()
    local owned_vehicle_count = 0
    for _, _ in pairs(M.ownership) do
      owned_vehicle_count = owned_vehicle_count + 1
    end
    if owned_vehicle_count >= network.connection.server_info.max_vehicles_per_client then
      enable_spawning(false)
    else
      enable_spawning(true)
    end
end

local function send_vehicle_config(vehicle_id)
  local vehicle = be:getObjectByID(vehicle_id)
  if vehicle then
    vehicle:queueLuaCommand("kiss_vehicle.send_vehicle_config()")
  end
end

local function send_vehicle_config_inner(id, parts_config, data)
  for k, v in pairs(M.id_map) do
    if v == id and not M.ownership[id] then return end
  end
  local data = jsonDecode(data)
  local vehicle = be:getObjectByID(id)
  local metal_data = vehicle:getMetallicPaintData()
  local color = vehicle.color
  local palete_0 = vehicle.colorPalette0
  local palete_1 = vehicle.colorPalette1
  local plate = vehicle.licenseText
  local position = vec3(data.position)
  local rotation = quat(data.rotation)
  local vehicle_data = {}
  vehicle_data.parts_config = parts_config
  vehicle_data.in_game_id = id
  vehicle_data.color = color_to_table(color, metal_data[1])
  vehicle_data.palete_0 = color_to_table(palete_0, metal_data[2])
  vehicle_data.palete_1 = color_to_table(palete_1, metal_data[3])
  vehicle_data.plate = plate
  vehicle_data.name = vehicle:getJBeamFilename()
  vehicle_data.position = {position.x, position.y, position.z}
  vehicle_data.rotation = {rotation.x, rotation.y, rotation.z, rotation.w}
  vehicle_data.server_id = 0
  vehicle_data.owner = 0
  network.send_data(
    {
      VehicleData = vehicle_data
    },
    true
  )
end

local function spawn_vehicle(data)
  local model_info = core_vehicles.getModel(data.name)
  if tableSize(model_info) == 0 then
    print("Rejected modded vehicle spawn " .. data.name)
    return
  end

  local away = true
  if kisstransform.raw_transforms[data.server_id] then
    away = (vec3(kisstransform.raw_transforms[data.server_id].position):distance(vec3(getCameraPosition())) > kissui.view_distance[0])
  else
    away = (vec3(data.position):distance(vec3(getCameraPosition())) > kissui.view_distance[0])
  end
  if M.loading_map or M.delay_spawns then
    print("Buffering vehicle")
    M.vehicle_buffer[data.server_id] = data
    return
  elseif away and kissui.enable_view_distance[0] then
    print("Buffering vehicle")
    M.vehicle_buffer[data.server_id] = data
    return
  end
  if data.owner == network.get_client_id() then
    print("Vehicle belongs to local client, setting ownership")
    M.id_map[data.server_id] = data.in_game_id
    M.ownership[data.in_game_id] = data.server_id
    M.server_ids[data.in_game_id] = data.server_id
    update_ownership_limits()
    be:getObjectByID(data.in_game_id):queueLuaCommand("extensions.hook('kissUpdateOwnership', true)")
    return
  end
  if M.id_map[data.server_id] then return end
  local current_vehicle = be:getPlayerVehicle(0)
  local parts_config = jsonDecode(data.parts_config)
  local c = data.color
  local plate = data.plate
  local cp0 = data.palete_0
  local cp1 = data.palete_1
  local name = data.name
  if name == "unicycle" then
    print("Attempt to spawn player")
    kissplayers.spawn_player(data)
    return
  end
  
  print("Attempt to spawn vehicle "..name)
  local options = { 
    vehicleName = "mp_veh",
    pos = vec3(data.position),
    rot = quat(data.rotation),
    config = serialize(parts_config),
    paint  = table_to_paint(c),
    paint2 = table_to_paint(cp0),
    paint3 = table_to_paint(cp1),
    autoEnterVehicle = false
  }
  options = sanitizeVehicleSpawnOptions(name, options)
  
  local spawned = spawn.spawnVehicle(name, options.config, options.pos, options.rot, options)
  if not spawned then return end
  local p = data.position
  local r = data.rotation
  spawned:setPositionRotation(p[1], p[2], p[3], r[1], r[2], r[3], r[4])
  if plate ~= nil then
    extensions.core_vehicles.setPlateText(plate, spawned:getID())
  end
  M.id_map[data.server_id] = spawned:getID()
  M.server_ids[spawned:getID()] = data.server_id
  kisstransform.inactive[spawned:getID()] = false
  --if current_vehicle then be:enterVehicle(0, current_vehicle) end
  spawned:queueLuaCommand("extensions.hook('kissUpdateOwnership', false)")
end

local function onUpdate(dt)
  if not network.connection.connected then return end
  if (getMissionFilename():lower() ~= network.connection.server_info.map:lower()) and (getMissionPath():lower() ~= network.connection.server_info.map:lower()) and not M.loading_map then
    network.disconnect()
  end
  -- Track color and plate changes
  meta_timer = meta_timer + dt
  if meta_timer >= 1 then
    send_vehicle_meta_updates()
    meta_timer = meta_timer - 1
  end

  local tick_time = (1/network.connection.tickrate)
  if timer <  tick_time then
    timer = timer + dt
  else
    timer = timer - tick_time
    for i, v in pairs(vehiclemanager.ownership) do
      local vehicle = be:getObjectByID(i)
      if vehicle and (not kisstransform.inactive[i]) then
        send_vehicle_update(vehicle)
        vehicle:queueLuaCommand("kiss_electrics.send()")
      end
    end
  end

  for k, v in pairs(M.id_map) do
    if not M.ownership[v] then
      local vehicle = be:getObjectByID(v)
      if vehicle and (not kisstransform.inactive[v]) then
        vehicle:queueLuaCommand("kiss_vehicle.update_eligible_nodes()")
      end
    end
  end
  if not (M.loading_map or M.delay_spawns) then
    local to_remove = {}
    for k, vehicle in pairs(M.vehicle_buffer) do
      local t = kisstransform.raw_transforms[k]
      if t and not ((vec3(t.position):distance(vec3(getCameraPosition())) > kissui.view_distance[0]) and kissui.enable_view_distance[0]) then
        spawn_vehicle(vehicle)
        table.insert(to_remove, k)
      end
    end
    for _, v in pairs(to_remove) do
      M.vehicle_buffer[v] = nil
    end
  end
end

local function update_vehicle(data)
  kisstransform.raw_transforms[data.vehicle_id] = data.transform
    -- If vehicle is a unicycle(Walking mode character), sync it differently
  local character = kissplayers.players[data.vehicle_id]
  if character then
    kissplayers.player_transforms[data.vehicle_id].target_position = vec3(data.transform.position)
    kissplayers.player_transforms[data.vehicle_id].rotation = data.transform.rotation
    kissplayers.player_transforms[data.vehicle_id].velocity = vec3(data.transform.velocity)
    kissplayers.player_transforms[data.vehicle_id].time_past = clamp(get_current_time() - data.sent_at, 0, 0.3) + 0.0001
    return
  end
 
  local id = M.id_map[data.vehicle_id]
  if not id then return end
  if M.ownership[id] then return end
  if data.generation <= (M.packet_gen_buffer[id] or -1) then return end
  M.packet_gen_buffer[id] = data.generation
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end

  kisstransform.update_vehicle_transform(data)
  if not kisstransform.inactive[id] then
    vehicle:queueLuaCommand("kiss_input.apply(" .. string.format("%q", jsonEncode(data.electrics)) .. ")")
    if not M.coupled_to[id] then
      vehicle:queueLuaCommand("kiss_gearbox.apply(" .. string.format("%q", jsonEncode(data.gearbox)) .. ")")
    end
  end
end

local function remove_vehicle(data)
  local id = data
  if kissplayers.players[id] then
    kissplayers.players[id]:delete()
    kissplayers.players[id] = nil
    kissplayers.player_transforms[id] = nil
    return
  end
  local local_id = M.id_map[id] or -1
  local vehicle = be:getObjectByID(local_id)
  if vehicle then
    vehicle:setActive(1)
    vehicle:delete()
    M.id_map[id] = nil
    M.ownership[local_id] = nil
    M.vehicle_updates_buffer[local_id] = nil
    kisstransform.received_transforms[local_id] = nil
    -- Clean up any coupling involving this vehicle
    M.coupled_to[local_id] = nil
    for k, v in pairs(M.coupled_to) do
      if v.truck_id == local_id then M.coupled_to[k] = nil end
    end
    update_ownership_limits()
  else
    M.vehicle_buffer[id] = nil
  end
end

local function reset_vehicle(data)
  local id = data.vehicle_id
  id = M.id_map[id] or -1
  
  local position = data.position
  local rotation = data.rotation
  
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
  if vehicle then
    vehicle:reset()
    vehicle:setPositionRotation(
      position[1],
      position[2],
      position[3],
      rotation[1],
      rotation[2],
      rotation[3],
      rotation[4]
    )
  end
end

local function update_vehicle_meta(data)
  local id = M.id_map[data.vehicle_id or -1] or -1
  if M.ownership[id] then return end
  local vehicle = be:getObjectByID(id)
  if not vehicle then return end
  local plate = data.plate
  
  local color = data.colors_table[1]
  local palete_0 = data.colors_table[2]
  local palete_1 = data.colors_table[3]
  local color_tables = {
    color,
    palete_0,
    palete_1
  }
  -- Apply plate
  if plate ~= nil then
    extensions.core_vehicles.setPlateText(plate, id)
  end

  -- Apply colors
  local vd = extensions.core_vehicle_manager.getVehicleData(id)
  if not vd or not vd.config or not vd.config.paints then return end
  
  for i=1,3 do
    local ct = color_tables[i]
    vd.config.paints[i] =  table_to_paint(ct)
    extensions.core_vehicle_manager.liveUpdateVehicleColors(id, vehicle, i, table_to_color(ct))
  end
  vehicle:setField('partConfig', '', serialize(vd.config))
end

local function electrics_diff_update(data)
  local id = M.id_map[data[1] or -1]
  if id and not M.ownership[id] then
    local vehicle = be:getObjectByID(id)
    if not vehicle then return end
    local data = jsonEncode(data[2].diff)
    vehicle:queueLuaCommand("kiss_electrics.apply_diff(" .. string.format("%q", data) .. ")")
  end
end

-- Classify coupler tag into internal path identifier for sync branching.
-- Detected once at attach time, stored on cluster state, never recomputed.
classify_hitch = function(coupler_tag)
  if coupler_tag == "fifthwheel_v2" or coupler_tag == "fifthwheel" then
    return "fifthwheel"
  elseif coupler_tag == "pintle" then
    return "pintle"
  end
  -- tow_hitch, gooseneck_hitch, and any unknown tag → ball hitch (safe 3-DOF default)
  return "ball"
end

-- Dedup tables for coupler events. One physical coupling can fire up to 3
-- times: once per owned vehicle via the vehicle-side kiss_couplers hook, plus
-- once via the GE-level BeamNG dispatch to M.onCouplerAttached. Time-based
-- cooldown suppresses duplicates within a short window while still allowing
-- quick re-coupling after a brief detach.
local coupler_send_cooldown = 2.0
local last_attach_sent = {}
local last_detach_sent = {}

local function coupler_pair_key(a, b)
  return math.min(a, b) .. "_" .. math.max(a, b)
end

-- Shared send path for coupler attach events. Takes a decoded table so both
-- the vehicle-side JSON path (attach_coupler_inner) and the new GE-level
-- hook (onCouplerAttached) can feed into the same dedup + network send.
local function send_coupler_attach(data)
  if not data.obj_a or not data.obj_b then return end
  if data.obj_a == data.obj_b then return end
  if not M.server_ids[data.obj_a] or not M.server_ids[data.obj_b] then return end
  local key = coupler_pair_key(data.obj_a, data.obj_b)
  local now = os.clock()
  local last = last_attach_sent[key]
  if last and (now - last) < coupler_send_cooldown then
    print("[KISS_COUPLER] Suppressed duplicate attach event for pair " .. key)
    return
  end
  last_attach_sent[key] = now
  last_detach_sent[key] = nil
  print("[KISS_COUPLER] Sending attach event: obj_a=" .. data.obj_a .. " obj_b=" .. data.obj_b)
  local payload = {
    obj_a = M.server_ids[data.obj_a],
    obj_b = M.server_ids[data.obj_b],
    node_a_id = data.node_a_id,
    node_b_id = data.node_b_id,
    coupler_tag = data.coupler_tag or "",
  }
  network.send_data({ CouplerAttached = payload }, true)
end

local function send_coupler_detach(data)
  if not data.obj_a or not data.obj_b then return end
  if data.obj_a == data.obj_b then return end
  if not M.server_ids[data.obj_a] or not M.server_ids[data.obj_b] then return end
  local key = coupler_pair_key(data.obj_a, data.obj_b)
  local now = os.clock()
  local last = last_detach_sent[key]
  if last and (now - last) < coupler_send_cooldown then
    return
  end
  last_detach_sent[key] = now
  last_attach_sent[key] = nil
  local payload = {
    obj_a = M.server_ids[data.obj_a],
    obj_b = M.server_ids[data.obj_b],
    node_a_id = data.node_a_id,
    node_b_id = data.node_b_id,
  }
  network.send_data({ CouplerDetached = payload }, true)
end

-- Vehicle-side JSON entry points (called from kiss_couplers via queueGameEngineLua)
local function attach_coupler_inner(data)
  send_coupler_attach(jsonDecode(data))
end

local function detach_coupler_inner(data)
  send_coupler_detach(jsonDecode(data))
end

-- GE-level hook: BeamNG fires this via extensions dispatch when beamstate
-- sees a coupler latch (subject to objectId <= obj2id dedup on the C++ side).
-- This catches ball-hitch L-key couplings whose vehicle-level callback may
-- land on a vehicle where kiss_couplers.onCouplerAttached short-circuits.
local function onCouplerAttached(objA, objB, nodeA, nodeB)
  if not network.connection.connected then return end
  if not objA or not objB or objA == objB then return end
  local owned_a = M.ownership[objA]
  local owned_b = M.ownership[objB]
  if not owned_a and not owned_b then return end
  -- Normalize so obj_a is the owned vehicle (matches kiss_couplers convention)
  local data
  if owned_a then
    data = { obj_a = objA, obj_b = objB, node_a_id = nodeA, node_b_id = nodeB, coupler_tag = "" }
  else
    data = { obj_a = objB, obj_b = objA, node_a_id = nodeB, node_b_id = nodeA, coupler_tag = "" }
  end
  send_coupler_attach(data)
end

local function onCouplerDetached(objA, objB, nodeA, nodeB)
  if not network.connection.connected then return end
  if not objA or not objB or objA == objB then return end
  local owned_a = M.ownership[objA]
  local owned_b = M.ownership[objB]
  if not owned_a and not owned_b then return end
  local data
  if owned_a then
    data = { obj_a = objA, obj_b = objB, node_a_id = nodeA, node_b_id = nodeB }
  else
    data = { obj_a = objB, obj_b = objA, node_a_id = nodeB, node_b_id = nodeA }
  end
  send_coupler_detach(data)
end

-- Belt-and-suspenders hook: BeamNG fires onObjectCouplingChange with the full
-- attachedCouplers table for a vehicle whenever its coupling state changes.
-- We diff against a cached snapshot and emit synthetic attach/detach events
-- for anything the per-event onCouplerAttached path may have missed.
local function onObjectCouplingChange(objectId, couplerData)
  if not network.connection.connected then return end
  if not M.ownership[objectId] then return end
  if type(couplerData) ~= "table" then couplerData = {} end
  local prev = M.known_couplings[objectId] or {}
  local curr = {}
  for nodeId, entry in pairs(couplerData) do
    if type(entry) == "table" and entry.obj2id and entry.obj2nodeId then
      curr[nodeId] = { obj2id = entry.obj2id, obj2nodeId = entry.obj2nodeId }
    end
  end
  -- New couplings
  for nodeId, entry in pairs(curr) do
    local was = prev[nodeId]
    if not was or was.obj2id ~= entry.obj2id or was.obj2nodeId ~= entry.obj2nodeId then
      print("[KISS_COUPLER] onObjectCouplingChange attach: " .. objectId .. " node " .. nodeId .. " -> " .. entry.obj2id)
      send_coupler_attach({
        obj_a = objectId, obj_b = entry.obj2id,
        node_a_id = nodeId, node_b_id = entry.obj2nodeId,
        coupler_tag = "",
      })
    end
  end
  -- Removed couplings
  for nodeId, entry in pairs(prev) do
    if not curr[nodeId] then
      print("[KISS_COUPLER] onObjectCouplingChange detach: " .. objectId .. " node " .. nodeId)
      send_coupler_detach({
        obj_a = objectId, obj_b = entry.obj2id,
        node_a_id = nodeId, node_b_id = entry.obj2nodeId,
      })
    end
  end
  M.known_couplings[objectId] = curr
end

local function attach_coupler(data)
  if data.obj_a == data.obj_b then return end -- Ignore self-coupling
  local obj_a = M.id_map[data.obj_a]
  local obj_b = M.id_map[data.obj_b]
  if obj_a and obj_b then
    -- Never reposition a vehicle we own from an inbound network message.
    -- The remote receive path snaps obj_b via setPositionNoPhysicsReset to
    -- align coupler nodes, which would yank our own truck/trailer sideways
    -- when rebroadcast events bounce back to us.
    if M.ownership[obj_a] or M.ownership[obj_b] then return end
    -- Idempotency: if this pair is already coupled in either direction,
    -- skip the snap + reattach so duplicate inbound events don't disrupt
    -- the active physics constraint.
    local existing_a = M.coupled_to[obj_a]
    local existing_b = M.coupled_to[obj_b]
    if (existing_a and existing_a.truck_id == obj_b) or (existing_b and existing_b.truck_id == obj_a) then
      print("[KISS_COUPLER] Skipping duplicate coupling for " .. obj_a .. " <-> " .. obj_b)
      return
    end
    local vehicle = be:getObjectByID(obj_a)
    local vehicle_b = be:getObjectByID(obj_b)
    if not vehicle then return end
    if not vehicle_b then return end
    if vec3(vehicle:getPosition()):distance(vec3(vehicle_b:getPosition())) > 15 then return end
    local node_a_pos = vec3(vehicle:getPosition()) + vec3(vehicle:getNodePosition(data.node_a_id))
    local node_b_pos = vec3(vehicle_b:getPosition()) + vec3(vehicle_b:getNodePosition(data.node_b_id))
    local pos = vec3(vehicle_b:getPosition()) + (node_a_pos - node_b_pos)
    vehicle_b:setPositionNoPhysicsReset(Point3F(pos.x, pos.y, pos.z))
    vehicle_b:queueLuaCommand("kiss_couplers.attach_coupler("..data.node_b_id..")")
    -- Cache coupler offset vectors in local space (from CG to hitch point).
    -- These are stored once at attach time and used every tick for offset composition.
    local trailer_offset = vehicle:getNodePosition(data.node_a_id)
    local truck_offset = vehicle_b:getNodePosition(data.node_b_id)
    local hitch_type = classify_hitch(data.coupler_tag or "")
    M.coupled_to[obj_a] = {
      truck_id = obj_b,
      node_a = data.node_a_id,
      node_b = data.node_b_id,
      hitch_type = hitch_type,
      -- Full 3D offset vectors: vehicle CG → coupling point, in vehicle local space
      trailer_offset = {trailer_offset.x, trailer_offset.y, trailer_offset.z},
      truck_offset = {truck_offset.x, truck_offset.y, truck_offset.z},
    }
    M.coupled_trucks[obj_b] = obj_a
    print("[KISS_COUPLER] Hitch type: " .. hitch_type .. " (tag: " .. (data.coupler_tag or "nil") .. ")")
    -- Notify both vehicles of their coupled state
    vehicle:queueLuaCommand("kiss_electrics.set_coupled(true)")
    vehicle_b:queueLuaCommand("kiss_electrics.set_coupled(true)")
    -- Release parking brake on the trailer — trailers don't send VehicleUpdate
    -- (no input/gearbox data) so kiss_input.apply never fires for them
    vehicle:queueLuaCommand("input.event('parkingbrake', 0, 2)")
    print("[KISS_COUPLER] Marked vehicle " .. obj_a .. " (trailer) as coupled to " .. obj_b .. " (truck)")
  end
end

local function detach_coupler(data)
  local obj_a = M.id_map[data.obj_a]
  local obj_b = M.id_map[data.obj_b]
  if obj_a and obj_b then
    -- Never act on inbound detach for a vehicle we own; the owner's local
    -- physics already handled it.
    if M.ownership[obj_a] or M.ownership[obj_b] then return end
    local vehicle = be:getObjectByID(obj_a)
    local vehicle_b = be:getObjectByID(obj_b)
    if not vehicle then return end
    if not vehicle_b then return end
    if vehicle ~= vehicle_b and vec3(vehicle:getPosition()):distance(vec3(vehicle_b:getPosition())) > 15 then return end
    vehicle:queueLuaCommand("kiss_couplers.detach_coupler("..data.node_a_id..")")
    -- Clear coupling tracking in both directions
    M.coupled_to[obj_b] = nil
    M.coupled_to[obj_a] = nil
    M.coupled_trucks[obj_a] = nil
    M.coupled_trucks[obj_b] = nil
    -- Notify both vehicles they are no longer coupled
    vehicle:queueLuaCommand("kiss_electrics.set_coupled(false)")
    vehicle_b:queueLuaCommand("kiss_electrics.set_coupled(false)")
  end
end

local function set_position(data)
  local id = M.id_map[data[1] or -1] or -1
  local vehicle = be:getObjectByID(id)
  if vehicle then
    vehicle:setPositionNoPhysicsReset(Point3F(data[2][1], data[2][2], data[2][3]))
  end
end

local function set_position_rotation(data)
  local id = M.id_map[data[1] or -1] or -1
  local vehicle = be:getObjectByID(id)
  if vehicle then
    vehicle:setPosRot(data[2][1], data[2][2], data[2][3], data[3][1], data[3][2], data[3][3], data[3][4])
  end
end

local function reset_in_place(data)
  local id = M.id_map[data or -1] or -1
  local vehicle = be:getObjectByID(id)
  if vehicle then
    vehicle:reset()
  end
end

local function onVehicleSpawned(id)
  if not network.connection.connected then return end
  local vehicle = be:getObjectByID(id)
  local position = vehicle:getPosition()
  if first_vehicle then
    vehicle:setPosition(Point3F(position.x + math.random(-5, 5), position.y + math.random(-5, 5), position.z))
    vehicle:queueLuaCommand("recovery.saveHome()")
    first_vehicle = false
  end
  vehicle:queueLuaCommand("extensions.addModulePath('lua/vehicle/extensions/kiss_mp')")
  vehicle:queueLuaCommand("extensions.loadModulesInDirectory('lua/vehicle/extensions/kiss_mp')")
  send_vehicle_config(id)
  -- Attempt to workaround a bug from latest beamng update. Also prevents unicycle cloning(Somewhat)
  if vehicle:getJBeamFilename() == "unicycle" then
    for i = 0, be:getObjectCount() do
      local v = be:getObject(i)
      if v and (v:getID() ~= vehicle:getID()) and (v:getJBeamFilename() == "unicycle") then
        v:delete()
      end
    end
  end
end

local function onVehicleDestroyed(id)
  if not network.connection.connected then return end
  if M.ownership[id] then
    M.id_map[M.ownership[id]] = nil
    M.ownership[id] = nil
    network.send_data(
      {
        RemoveVehicle = id,
      },
      true
    )
    update_ownership_limits()
  end
  M.known_couplings[id] = nil
  -- Clear any coupling state referencing this vehicle
  if M.coupled_to[id] then
    local truck_id = M.coupled_to[id].truck_id
    if truck_id then M.coupled_trucks[truck_id] = nil end
    M.coupled_to[id] = nil
  end
  if M.coupled_trucks[id] then
    local trailer_id = M.coupled_trucks[id]
    M.coupled_to[trailer_id] = nil
    M.coupled_trucks[id] = nil
  end
end

local function onVehicleResetted(id)
  if not network.connection.connected then return end
  if M.ownership[id] then
    local vehicle = be:getObjectByID(id)
    local rotation = quat(vehicle:getRefNodeMatrix():toQuatF())
    local position = vec3(vehicle:getPosition())
    local data = { vehicle_id = id, position = {position.x, position.y, position.z}, rotation = {rotation.x, rotation.y, rotation.z, rotation.w}}
    
    network.send_data(
      {
        ResetVehicle = data,
      },
      true
    )
  end
end

local function onVehicleSwitched(_id, new_id)
  for i = 0, be:getObjectCount() do
    local v = be:getObject(i)
    if v and (v:getID() ~= new_id) and (v:getJBeamFilename() == "unicycle") then
      v:delete()
    end
  end
  if M.ownership[new_id] then
    network.send_data(
      {
        VehicleChanged = new_id,
      },
      true
    )
  end
end

local function onMissionLoaded(mission)
  M.is_network_session = network.connection.connected
  if not network.connection.connected then return end
  M.id_map = {}
  M.ownership = {}
  M.coupled_to = {}
  M.coupled_trucks = {}
  M.known_couplings = {}
  M.loading_map = false
  first_vehicle = true
end

M.onUpdate = onUpdate
M.get_current_time = get_current_time
M.update_vehicle = update_vehicle
M.send_vehicle_config = send_vehicle_config
M.send_vehicle_config_inner = send_vehicle_config_inner
M.spawn_vehicle = spawn_vehicle
M.update_vehicle_input = update_vehicle_input
M.update_vehicle_gearbox = update_vehicle_gearbox
M.rotate_nodes = rotate_nodes
M.remove_vehicle = remove_vehicle
M.reset_vehicle = reset_vehicle
M.update_vehicle_meta = update_vehicle_meta
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleResetted = onVehicleResetted
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onMissionLoaded = onMissionLoaded
M.onFreeroamLoaded = onMissionLoaded
M.electrics_diff_update = electrics_diff_update
M.attach_coupler = attach_coupler
M.detach_coupler = detach_coupler
M.attach_coupler_inner = attach_coupler_inner
M.detach_coupler_inner = detach_coupler_inner
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.onObjectCouplingChange = onObjectCouplingChange

M.set_position = set_position
M.set_position_rotation = set_position_rotation
M.reset_in_place = reset_in_place

return M
