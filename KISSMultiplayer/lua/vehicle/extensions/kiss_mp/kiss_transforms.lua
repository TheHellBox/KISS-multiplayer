-- KissMP Transforms - Direct state replay with prediction and blending
-- Phase 1b implementation

local M = {}
-- kiss_sync is loaded as a global vehicle extension module

M.debug = true  -- Enable debug logging
M.cooldown_timer = 2
M.sync_id = nil  -- Vehicle ID for sync state tracking

-- Get current transform from sync module (includes prediction + blending)
local function get_synced_transform(current_time)
  if not M.sync_id then return nil end
  return kiss_sync.update_and_get_transform(M.sync_id, current_time)
end

-- Handle large corrections (teleport prevention)
local function try_rude(synced_transform)
  local current_pos = vec3(obj:getPosition())
  local distance = synced_transform.position:distance(current_pos)
  if distance > 6 then
    -- Large correction needed - use direct position reset
    local p = synced_transform.position
    obj:queueGameEngineLua("be:getObjectByID("..obj:getID().."):setPositionNoPhysicsReset(Point3F("..p.x..", "..p.y..", "..p.z.."))")
    obj:setRotation(synced_transform.rotation)
    return true
  end
  return false
end

local function draw_debug(synced_transform)
  obj.debugDrawProxy:drawSphere(0.3, synced_transform.position:toFloat3(), color(0,255,0,100))
  local current_pos = vec3(obj:getPosition())
  obj.debugDrawProxy:drawSphere(0.3, current_pos:toFloat3(), color(255,0,0,100))
  -- Draw blend progress if active
  local blend_progress = kiss_sync.get_blend_progress(M.sync_id, M.last_update_time or 0)
  if blend_progress < 1.0 then
    obj.debugDrawProxy:drawText("Blend: " .. math.floor(blend_progress * 100) .. "%", current_pos:toFloat3(), color(255,255,0,255))
  end
end

local function update(dt)
  -- DEBUG: Log update call
  if M.debug and dt <= 0.1 then
    print("[kiss_transforms.update] obj=" .. tostring(obj) .. " id=" .. tostring(obj:getID()) .. " sync_id=" .. tostring(M.sync_id) .. " dt=" .. tostring(dt))
  end

  if M.cooldown_timer > 0 then
    M.cooldown_timer = M.cooldown_timer - clamp(dt, 0, 0.02)
    return
  end

  if dt > 0.1 then
    if M.debug then
      print("[kiss_transforms.update] BLOCKED by large dt: " .. dt)
    end
    return
  end

  -- Get synced transform from sync module (includes prediction + active blending)
  local current_time = obj:getTime() or 0
  M.last_update_time = current_time

  if M.debug then
    print("[kiss_transforms.update] current_time=" .. current_time .. " calling get_synced_transform")
  end

  local synced_transform = get_synced_transform(current_time)

  if not synced_transform then
    if M.debug then
      print("[kiss_transforms.update] BLOCKED: get_synced_transform returned nil")
    end
    return
  end

  if M.debug then
    print("[kiss_transforms.update] Got synced_transform pos=(" .. synced_transform.position.x .. "," .. synced_transform.position.y .. "," .. synced_transform.position.z .. ")")
  end

  -- Handle large corrections (teleport prevention)
  if try_rude(synced_transform) then
    if M.debug then
      print("[kiss_transforms.update] try_rude triggered - direct reset applied")
      draw_debug(synced_transform)
    end
    return
  end

  -- Force-based velocity-matched replay - inject forces to match target velocity
  if M.debug then
    print("[kiss_transforms.update] APPLYING forces v=" .. tostring(synced_transform.velocity[1]) .. "," .. tostring(synced_transform.velocity[2]) .. "," .. tostring(synced_transform.velocity[3]) .. " w=" .. tostring(synced_transform.angular_velocity[1]) .. "," .. tostring(synced_transform.angular_velocity[2]) .. "," .. tostring(synced_transform.angular_velocity[3]))
  end
  kiss_vehicle.apply_linear_velocity_ang_torque(
    synced_transform.velocity[1], synced_transform.velocity[2], synced_transform.velocity[3],
    synced_transform.angular_velocity[1], synced_transform.angular_velocity[2], synced_transform.angular_velocity[3]
  )

  if M.debug then
    draw_debug(synced_transform)
  end
end

-- Apply authoritative snapshot from wire
-- Called by network.lua when VehicleUpdate arrives
local function set_target_transform(raw)
  local transform = jsonDecode(raw)

  -- Initialize sync_id from transform data
  if transform.owner then
    M.sync_id = transform.owner
  end

  if not M.sync_id then return end

  -- Get current time for blend calculation
  local current_time = obj:getTime() or transform.sent_at or 0

  -- Apply snapshot to sync module (handles prediction + blending setup)
  kiss_sync.apply_snapshot(
    M.sync_id,
    transform,
    transform.sent_at or current_time,
    transform.generation or 0,
    current_time,
    0.15  -- 150ms blend duration
  )

  -- Phase 1c: Apply node positions from deformation channel (direct state replay)
  if transform.deformation and transform.deformation.node_positions then
    if kiss_nodes and kiss_nodes.apply_nodes then
      kiss_nodes.apply_nodes(transform.deformation.node_positions)
    end
  end
end

local function onExtensionLoaded()
  -- Initialize sync state with current vehicle position
  M.sync_id = obj:getID()
  local current_pos = vec3(obj:getPosition())
  local current_rot = quat(obj:getRotation())

  -- Set initial state to avoid snap on first update
  local current_time = obj:getTime() or 0
  local initial_transform = {
    position = {current_pos.x, current_pos.y, current_pos.z},
    rotation = {current_rot.x, current_rot.y, current_rot.z, current_rot.w},
    velocity = {0, 0, 0},
    angular_velocity = {0, 0, 0},
  }
  kiss_sync.apply_snapshot(M.sync_id, initial_transform, current_time, 0, current_time, 0)

  M.cooldown_timer = 1.5
end

local function onReset()
  -- Reset sync state on vehicle reset
  if M.sync_id then
    kiss_sync.reset_sync_state(M.sync_id)
  end
  M.cooldown_timer = 0.2
end

-- Export functions
M.set_target_transform = set_target_transform
M.update = update
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.get_synced_transform = get_synced_transform

return M
