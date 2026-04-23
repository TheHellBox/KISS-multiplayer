local M = {}
local imgui = ui_imgui

-- Push current tuning values to every active vehicle's sync modules.
-- Called on every slider change so values take effect live, and also from
-- vehiclemanager.onVehicleSpawned so freshly-spawned vehicles pick up current
-- values on spawn.
local function push_tuning_to_all_vehicles()
  local t = kissui.tuning
  local layer1_cmd = string.format(
    "kiss_transforms.set_layer1_tuning(%d, %f, %f, %f)",
    t.position_pull_gain[0],
    t.position_deadband[0],
    t.velocity_deadband[0],
    t.max_delta_v[0]
  )
  local drift_cmd = string.format(
    "kiss_transforms.set_drift_tuning(%f)",
    t.layer1_drift_nudge_gain[0]
  )
  local drift_mode_cmd = string.format(
    "kiss_transforms.set_drift_mode(%s)",
    t.layer1_use_drift_integral[0] and "true" or "false"
  )
  local prediction_cmd = string.format(
    "kiss_transforms.set_prediction_tuning(%s)",
    t.layer1_enable_yaw_prediction[0] and "true" or "false"
  )
  local course_cmd = string.format(
    "kiss_transforms.set_heading_hold_tuning(%f)",
    t.layer1_heading_hold_yaw_trim_gain[0]
  )
  local transforms_cmd = string.format(
    "kiss_transforms.set_filter_tuning(%f, %f, %f, %f, %f, %f, %f, %f)",
    t.layer1_z_weight[0],
    t.layer1_tilt_weight[0],
    t.layer1_vz_weight[0],
    t.layer1_tilt_rate_weight[0],
    t.layer1_z_deadband[0],
    math.rad(t.layer1_tilt_deadband_deg[0]),
    t.layer1_vz_deadband[0],
    t.layer1_tilt_rate_deadband[0]
  )
  local controller_cmd = string.format(
    "kiss_vehicle.set_controller_tuning(%f, %f, %f, %f, %f, %f)",
    t.layer1_frame_planar_gain[0],
    t.layer1_yaw_gain[0],
    t.layer1_yaw_rate_gain[0],
    t.layer1_support_gain[0],
    t.layer1_frame_planar_max_dv[0],
    t.layer1_yaw_max_dv[0]
  )
  local geometry_cmd = string.format(
    "kiss_vehicle.set_geometry_tuning(%f, %s)",
    t.layer1_shell_inset_cm[0],
    t.layer1_debug_viz[0] and "true" or "false"
  )
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand(layer1_cmd)
      vehicle:queueLuaCommand(drift_cmd)
      vehicle:queueLuaCommand(drift_mode_cmd)
      vehicle:queueLuaCommand(prediction_cmd)
      vehicle:queueLuaCommand(course_cmd)
      vehicle:queueLuaCommand(transforms_cmd)
      vehicle:queueLuaCommand(controller_cmd)
      vehicle:queueLuaCommand(geometry_cmd)
    end
  end
end

M.push_tuning_to_all_vehicles = push_tuning_to_all_vehicles

local function draw()
  local t = kissui.tuning
  local changed = false

  imgui.PushTextWrapPos(0)
  imgui.Text("Motion-first sync tuning. Changes apply live to all active vehicles.")
  imgui.PopTextWrapPos()
  imgui.Dummy(imgui.ImVec2(0, 5))

  imgui.Dummy(imgui.ImVec2(0, 8))
  imgui.Text("Stage 1: Rigid Motion")
  imgui.TextWrapped("Primary path-hold and safety controls for the receiver-side rigid envelope replay. Layer 1 owns normal driving; Layer 2 no longer carries motion.")
  imgui.Dummy(imgui.ImVec2(0, 4))

  imgui.Text("Position pull gain (secondary position spring added on top of velocity matching; 0 = pure velocity matching and slow drift cleanup, high = faster convergence but more seam fighting and snap when targets disagree)")
  if imgui.SliderInt("###position_pull_gain", t.position_pull_gain, 0, 200) then
    changed = true
  end

  imgui.Text("Position dead-band (metres; 0 = always react to tiny position error and chase noise, high = ignore small offsets and allow more bounded body mismatch before correction starts)")
  if imgui.SliderFloat("###position_deadband", t.position_deadband, 0.0, 0.2) then
    changed = true
  end

  imgui.Text("Velocity dead-band (m/s; 0 = react to every tiny relative velocity and amplify idle jitter, high = ignore more residual motion and let chassis/wheels settle locally)")
  if imgui.SliderFloat("###velocity_deadband", t.velocity_deadband, 0.0, 2.0) then
    changed = true
  end

  imgui.Text("Max Δv per tick (m/s safety ceiling; low = very safe/soft but slow catch-up after error, high = faster correction but larger impulses when prediction or structure classification is wrong)")
  if imgui.SliderFloat("###max_delta_v", t.max_delta_v, 1.0, 50.0) then
    changed = true
  end

  imgui.Dummy(imgui.ImVec2(0, 6))
  imgui.Text("Yaw / support split:")

  imgui.Text("Frame planar gain (frame-trio-only x/y convergence; low = residual long-run drift recenters slowly, high = stronger path restoration without giving support planar authority)")
  if imgui.SliderFloat("###layer1_frame_planar_gain", t.layer1_frame_planar_gain, 0.0, 8.0) then
    changed = true
  end

  imgui.Text("Yaw gain (strong frame heading correction; low = heading lags/drifts, high = yaw snaps back faster but can feel harsher)")
  if imgui.SliderFloat("###layer1_yaw_gain", t.layer1_yaw_gain, 0.0, 8.0) then
    changed = true
  end

  imgui.Text("Yaw rate gain (vertical angular-rate correction on the frame trio; low = lazy heading recovery, high = faster self-correction but easier overshoot)")
  if imgui.SliderFloat("###layer1_yaw_rate_gain", t.layer1_yaw_rate_gain, 0.0, 8.0) then
    changed = true
  end

  imgui.Text("Support gain (mirrored shell support for z/pitch/roll only; 0 = frame trio owns path entirely, higher = more body support but more risk of shell-side compliance)")
  if imgui.SliderFloat("###layer1_support_gain", t.layer1_support_gain, 0.0, 1.5) then
    changed = true
  end

  imgui.Text("Frame planar max Δv (m/s clamp for the frame planar loop; low = safer but can leave steady-state offset, high = stronger recentering)")
  if imgui.SliderFloat("###layer1_frame_planar_max_dv", t.layer1_frame_planar_max_dv, 1.0, 60.0) then
    changed = true
  end

  imgui.Text("Yaw max Δv (m/s clamp for the frame-yaw loop; low = safer but slower heading catch-up, high = more decisive yaw correction)")
  if imgui.SliderFloat("###layer1_yaw_max_dv", t.layer1_yaw_max_dv, 1.0, 60.0) then
    changed = true
  end

  imgui.Text("Shell inset (cm; pushes mirrored support-node selection inward from outer body bounds to avoid bumper/fender picks)")
  if imgui.SliderFloat("###layer1_shell_inset_cm", t.layer1_shell_inset_cm, 0.0, 30.0) then
    changed = true
  end

  imgui.Text("Debug visualize Layer 1 nodes (frame refnodes green, support nodes orange)")
  if imgui.Checkbox("###layer1_debug_viz", t.layer1_debug_viz) then
    changed = true
  end

  imgui.Text("Use integral drift mitigation instead of nudge")
  if imgui.Checkbox("###layer1_use_drift_integral", t.layer1_use_drift_integral) then
    changed = true
  end

  imgui.Text(t.layer1_use_drift_integral[0]
    and "Drift integral strength (slow bounded planar+yaw trim during calm driving; 0 = off, higher = cancels steady-state bias faster but can hunt if pushed too far)"
    or "Drift nudge correction (rare planar no-reset nudges after persistent calm drift; 0 = off, higher = corrects long-horizon offset faster without always-on memory)")
  if imgui.SliderFloat("###layer1_drift_nudge_gain", t.layer1_drift_nudge_gain, 0.0, 0.1) then
    changed = true
  end

  imgui.Text("Yaw prediction (short capped yaw-only look-ahead; helps reduce turn-in lag from stale targets without re-enabling broad transform extrapolation)")
  if imgui.Checkbox("###layer1_enable_yaw_prediction", t.layer1_enable_yaw_prediction) then
    changed = true
  end

  imgui.Text("Heading-hold yaw trim (slow world-XY course-heading trim; low = less long-horizon recentering, high = stronger heading hold without changing the fast yaw loop)")
  if imgui.SliderFloat("###layer1_heading_hold_yaw_trim_gain", t.layer1_heading_hold_yaw_trim_gain, 0.0, 2.0) then
    changed = true
  end

  imgui.Dummy(imgui.ImVec2(0, 6))
  imgui.Text("Weak-channel filter (suspension/contact-local motion):")

  imgui.Text("Z weight (0 = keep local ride height, 1 = fully match remote vertical body motion)")
  if imgui.SliderFloat("###layer1_z_weight", t.layer1_z_weight, 0.0, 1.0) then
    changed = true
  end

  imgui.Text("Pitch/roll weight (0 = keep local tilt, 1 = fully match remote body tilt)")
  if imgui.SliderFloat("###layer1_tilt_weight", t.layer1_tilt_weight, 0.0, 1.0) then
    changed = true
  end

  imgui.Text("Vertical velocity weight (0 = keep local heave velocity, 1 = fully match remote vertical velocity)")
  if imgui.SliderFloat("###layer1_vz_weight", t.layer1_vz_weight, 0.0, 1.0) then
    changed = true
  end

  imgui.Text("Roll/pitch rate weight (0 = keep local tilt-rate, 1 = fully match remote roll/pitch rates)")
  if imgui.SliderFloat("###layer1_tilt_rate_weight", t.layer1_tilt_rate_weight, 0.0, 1.0) then
    changed = true
  end

  imgui.Text("Z dead-band (metres; weak vertical corrections below this are ignored)")
  if imgui.SliderFloat("###layer1_z_deadband", t.layer1_z_deadband, 0.0, 0.2) then
    changed = true
  end

  imgui.Text("Pitch/roll dead-band (degrees; small tilt differences below this are ignored)")
  if imgui.SliderFloat("###layer1_tilt_deadband_deg", t.layer1_tilt_deadband_deg, 0.0, 10.0) then
    changed = true
  end

  imgui.Text("Vertical velocity dead-band (m/s; weak heave velocity differences below this are ignored)")
  if imgui.SliderFloat("###layer1_vz_deadband", t.layer1_vz_deadband, 0.0, 1.0) then
    changed = true
  end

  imgui.Text("Roll/pitch rate dead-band (rad/s; weak tilt-rate differences below this are ignored)")
  if imgui.SliderFloat("###layer1_tilt_rate_deadband", t.layer1_tilt_rate_deadband, 0.0, 1.0) then
    changed = true
  end

  if changed then
    push_tuning_to_all_vehicles()
    if kissconfig and kissconfig.save_config then
      kissconfig.save_config()
    end
  end
end

M.draw = draw

return M
