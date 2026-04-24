local M = {}
local imgui = ui_imgui
local BROADCAST_DEBOUNCE_S = 0.25

local pending_broadcast = false
local pending_broadcast_timer = 0.0
local local_revision = 0
local push_tuning_to_all_vehicles
local last_session_tuning = {
  changed_at_ms = 0,
  author_id = 0,
  revision = 0,
}

local function clamp01_3(value)
  return math.max(0.0, math.min(3.0, value or 0.0))
end

local function is_newer_session_tuning(a, b)
  if not b then return true end
  if (a.changed_at_ms or 0) ~= (b.changed_at_ms or 0) then
    return (a.changed_at_ms or 0) > (b.changed_at_ms or 0)
  end
  if (a.author_id or 0) ~= (b.author_id or 0) then
    return (a.author_id or 0) > (b.author_id or 0)
  end
  return (a.revision or 0) > (b.revision or 0)
end

local function build_session_tuning_snapshot()
  local t = kissui.tuning
  local now_ms = math.floor(((network.socket.gettime() + (network.connection.time_offset or 0)) * 1000.0) + 0.5)
  local_revision = local_revision + 1
  return {
    changed_at_ms = now_ms,
    author_id = network.connection.client_id or 0,
    revision = local_revision,
    path_strength = clamp01_3(t.path_strength[0]),
    heading_strength = clamp01_3(t.heading_strength[0]),
    heading_hold = clamp01_3(t.heading_hold[0]),
    cross_track_hold = clamp01_3(t.cross_track_hold[0]),
    body_support = clamp01_3(t.body_support[0]),
    noise_rejection = clamp01_3(t.noise_rejection[0]),
    yaw_prediction = t.yaw_prediction[0] and true or false,
  }
end

local function apply_session_tuning_snapshot(data)
  local t = kissui.tuning
  t.path_strength[0] = clamp01_3(data.path_strength)
  t.heading_strength[0] = clamp01_3(data.heading_strength)
  t.heading_hold[0] = clamp01_3(data.heading_hold)
  t.cross_track_hold[0] = clamp01_3(data.cross_track_hold)
  t.body_support[0] = clamp01_3(data.body_support)
  t.noise_rejection[0] = clamp01_3(data.noise_rejection)
  t.yaw_prediction[0] = data.yaw_prediction and true or false
  push_tuning_to_all_vehicles()
end

local function schedule_tuning_broadcast()
  pending_broadcast = true
  pending_broadcast_timer = 0.0
end

-- Push current tuning values to every active vehicle's sync modules.
-- Called on every slider change so values take effect live, and also from
-- vehiclemanager.onVehicleSpawned so freshly-spawned vehicles pick up current
-- values on spawn.
function push_tuning_to_all_vehicles()
  local d = kissui.get_derived_sync_tuning()
  local layer1_cmd = string.format(
    "kiss_transforms.set_layer1_tuning(%d, %f, %f, %f)",
    d.position_pull_gain,
    d.position_deadband,
    d.velocity_deadband,
    d.max_delta_v
  )
  local prediction_cmd = string.format(
    "kiss_transforms.set_prediction_tuning(%s)",
    d.layer1_enable_yaw_prediction and "true" or "false"
  )
  local course_cmd = string.format(
    "kiss_transforms.set_heading_hold_tuning(%f)",
    d.layer1_heading_hold_yaw_trim_gain
  )
  local cross_track_cmd = string.format(
    "kiss_transforms.set_cross_track_tuning(%f)",
    d.layer1_cross_track_hold_gain
  )
  local transforms_cmd = string.format(
    "kiss_transforms.set_filter_tuning(%f, %f, %f, %f, %f, %f, %f, %f)",
    d.layer1_z_weight,
    d.layer1_tilt_weight,
    d.layer1_vz_weight,
    d.layer1_tilt_rate_weight,
    d.layer1_z_deadband,
    math.rad(d.layer1_tilt_deadband_deg),
    d.layer1_vz_deadband,
    d.layer1_tilt_rate_deadband
  )
  local controller_cmd = string.format(
    "kiss_vehicle.set_controller_tuning(%f, %f, %f, %f, %f, %f)",
    d.layer1_frame_planar_gain,
    d.layer1_yaw_gain,
    d.layer1_yaw_rate_gain,
    d.layer1_support_gain,
    d.layer1_frame_planar_max_dv,
    d.layer1_yaw_max_dv
  )
  local geometry_cmd = string.format(
    "kiss_vehicle.set_geometry_tuning(%f, %s)",
    d.layer1_shell_inset_cm,
    d.layer1_debug_viz and "true" or "false"
  )
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand(layer1_cmd)
      vehicle:queueLuaCommand(prediction_cmd)
      vehicle:queueLuaCommand(course_cmd)
      vehicle:queueLuaCommand(cross_track_cmd)
      vehicle:queueLuaCommand(transforms_cmd)
      vehicle:queueLuaCommand(controller_cmd)
      vehicle:queueLuaCommand(geometry_cmd)
    end
  end
end

M.push_tuning_to_all_vehicles = push_tuning_to_all_vehicles

function M.apply_session_tuning(data)
  if not data then return end
  if not is_newer_session_tuning(data, last_session_tuning) then return end
  last_session_tuning = {
    changed_at_ms = data.changed_at_ms or 0,
    author_id = data.author_id or 0,
    revision = data.revision or 0,
  }
  pending_broadcast = false
  pending_broadcast_timer = 0.0
  apply_session_tuning_snapshot(data)
end

function M.onUpdate(dt)
  if not pending_broadcast then return end
  if not network.connection.connected then return end
  pending_broadcast_timer = pending_broadcast_timer + dt
  if pending_broadcast_timer < BROADCAST_DEBOUNCE_S then return end

  pending_broadcast = false
  pending_broadcast_timer = 0.0

  local snapshot = build_session_tuning_snapshot()
  last_session_tuning = {
    changed_at_ms = snapshot.changed_at_ms,
    author_id = snapshot.author_id,
    revision = snapshot.revision,
  }
  network.send_data({
    SessionTuningUpdate = snapshot
  }, true)
end

local function draw()
  local t = kissui.tuning
  local changed = false

  imgui.PushTextWrapPos(0)
  imgui.Text("Motion-first sync tuning. Changes apply live to all active vehicles.")
  imgui.PopTextWrapPos()
  imgui.Dummy(imgui.ImVec2(0, 5))

  imgui.Text("Path Strength (how firmly the follower recenters in world XY)")
  if imgui.SliderFloat("###path_strength", t.path_strength, 0.0, 3.0) then
    changed = true
  end

  imgui.Text("Heading Strength (how strongly the frame path aligns and settles heading)")
  if imgui.SliderFloat("###heading_strength", t.heading_strength, 0.0, 3.0) then
    changed = true
  end

  imgui.Text("Heading Hold (slow course-over-ground correction for long-horizon wander)")
  if imgui.SliderFloat("###heading_hold", t.heading_hold, 0.0, 3.0) then
    changed = true
  end

  imgui.Text("Cross-Track Hold (slow sideways path recentering)")
  if imgui.SliderFloat("###cross_track_hold", t.cross_track_hold, 0.0, 3.0) then
    changed = true
  end

  imgui.Text("Body Support (how much z/tilt/heave body motion is replayed)")
  if imgui.SliderFloat("###body_support", t.body_support, 0.0, 3.0) then
    changed = true
  end

  imgui.Text("Noise Rejection (how much small jitter and road noise gets ignored)")
  if imgui.SliderFloat("###noise_rejection", t.noise_rejection, 0.0, 3.0) then
    changed = true
  end

  imgui.Text("Yaw prediction (short capped yaw-only look-ahead; helps reduce turn-in lag from stale targets without re-enabling broad transform extrapolation)")
  if imgui.Checkbox("###yaw_prediction", t.yaw_prediction) then
    changed = true
  end

  if changed then
    push_tuning_to_all_vehicles()
    schedule_tuning_broadcast()
  end
end

M.draw = draw

return M
