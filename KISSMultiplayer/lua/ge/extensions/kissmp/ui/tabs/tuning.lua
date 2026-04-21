local M = {}
local imgui = ui_imgui

-- Push current tuning values to every active vehicle's kiss_nodes module.
-- Called on every slider change so values take effect live, and also from
-- vehiclemanager.onVehicleSpawned so freshly-spawned vehicles pick up current
-- values on spawn.
local function push_tuning_to_all_vehicles()
  local t = kissui.tuning
  local cmd = string.format(
    "kiss_nodes.set_tuning(%d, %d, %d, %d, %d, %f, %f, %f)",
    t.position_scale[0],
    t.velocity_scale[0],
    t.position_epsilon[0],
    t.velocity_epsilon[0],
    t.position_pull_gain[0],
    t.position_deadband[0],
    t.velocity_deadband[0],
    t.max_delta_v[0]
  )
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand(cmd)
    end
  end
end

M.push_tuning_to_all_vehicles = push_tuning_to_all_vehicles

local function draw()
  local t = kissui.tuning
  local changed = false

  imgui.PushTextWrapPos(0)
  imgui.Text("Layer-2 sync tuning. Changes apply live to all active vehicles.")
  imgui.PopTextWrapPos()
  imgui.Dummy(imgui.ImVec2(0, 5))

  imgui.Text("Position scale (i16 units per metre)")
  if imgui.SliderInt("###position_scale", t.position_scale, 100, 10000) then
    changed = true
  end

  imgui.Text("Velocity scale (i16 units per m/s)")
  if imgui.SliderInt("###velocity_scale", t.velocity_scale, 10, 1000) then
    changed = true
  end

  imgui.Text("Position epsilon (skip entries with |deviation| <= this, in quantized units)")
  if imgui.SliderInt("###position_epsilon", t.position_epsilon, 0, 100) then
    changed = true
  end

  imgui.Text("Velocity epsilon (skip entries with |deviation| <= this, in quantized units)")
  if imgui.SliderInt("###velocity_epsilon", t.velocity_epsilon, 0, 100) then
    changed = true
  end

  imgui.Text("Position pull gain (velocity correction per metre of position error; 0 = disabled)")
  if imgui.SliderInt("###position_pull_gain", t.position_pull_gain, 0, 200) then
    changed = true
  end

  imgui.Dummy(imgui.ImVec2(0, 5))
  imgui.Text("Receiver-side gates (agnosticism + safety):")

  imgui.Text("Position dead-band (metres — skip impulse when |Δp| below this)")
  if imgui.SliderFloat("###position_deadband", t.position_deadband, 0.0, 0.2) then
    changed = true
  end

  imgui.Text("Velocity dead-band (m/s — skip impulse when |Δv| below this)")
  if imgui.SliderFloat("###velocity_deadband", t.velocity_deadband, 0.0, 2.0) then
    changed = true
  end

  imgui.Text("Max Δv per tick (m/s — hard ceiling on per-tick velocity change)")
  if imgui.SliderFloat("###max_delta_v", t.max_delta_v, 1.0, 50.0) then
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
