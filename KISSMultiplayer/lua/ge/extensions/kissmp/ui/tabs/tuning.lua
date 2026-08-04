local M = {}
local imgui = ui_imgui

-- Receiver-side velocity smoothing rate (Hz cutoff) consumed by kiss_sync.lua.
-- Default must match kiss_sync.M.REMOTE_VEL_SMOOTH_RATE so the slider state
-- matches the vehicle-side state on first open.
local vel_rate = imgui.FloatPtr(2.0)
local prediction_offset_ms = imgui.FloatPtr(0.0)
local linear_pull_scale = imgui.FloatPtr(1.0)
local angular_pull_scale = imgui.FloatPtr(0.65)
local owner_teleport_cooldown_ms = imgui.FloatPtr(500.0)
local remote_teleport_cooldown_ms = imgui.FloatPtr(500.0)
local teleport_reset_delay_ms = imgui.FloatPtr(500.0)

local function build_command()
  return string.format(
    "kiss_sync.set_smoothing_tuning(%f, %f); kiss_motion_controller.set_linear_pull_scale(%f); kiss_motion_controller.set_angular_pull_scale(%f)",
    vel_rate[0],
    prediction_offset_ms[0] * 0.001,
    linear_pull_scale[0],
    angular_pull_scale[0]
  )
end

local function push_to_vehicle(vehicle)
  if not vehicle then return end
  vehicle:queueLuaCommand(build_command())
  if vehiclemanager and vehiclemanager.set_teleport_tuning then
    vehiclemanager.set_teleport_tuning(
      owner_teleport_cooldown_ms[0] * 0.001,
      remote_teleport_cooldown_ms[0] * 0.001,
      teleport_reset_delay_ms[0] * 0.001
    )
  end
end

local function push_to_all_vehicles()
  local cmd = build_command()
  if vehiclemanager and vehiclemanager.set_teleport_tuning then
    vehiclemanager.set_teleport_tuning(
      owner_teleport_cooldown_ms[0] * 0.001,
      remote_teleport_cooldown_ms[0] * 0.001,
      teleport_reset_delay_ms[0] * 0.001
    )
  end
  for i = 0, be:getObjectCount() do
    local vehicle = be:getObject(i)
    if vehicle then
      vehicle:queueLuaCommand(cmd)
    end
  end
end

local function draw()
  imgui.PushTextWrapPos(0)
  imgui.Text("Receiver-side velocity smoothing.")
  imgui.Text("Higher = tracks new packets faster, less smoothing.")
  imgui.Text("Lower = heavier smoothing, more lag.")
  imgui.PopTextWrapPos()
  imgui.Separator()

  if imgui.SliderFloat("Velocity smooth rate", vel_rate, 0.0, 30.0, "%.1f Hz") then
    push_to_all_vehicles()
  end
  if imgui.SliderFloat("Prediction offset", prediction_offset_ms, -80.0, 80.0, "%.0f ms") then
    push_to_all_vehicles()
  end
  if imgui.SliderFloat("Linear pull scale", linear_pull_scale, 0.5, 1.5, "%.2fx") then
    push_to_all_vehicles()
  end
  if imgui.SliderFloat("Angular pull scale", angular_pull_scale, 0.2, 1.2, "%.2fx") then
    push_to_all_vehicles()
  end
  if imgui.SliderFloat("Owner teleport cooldown", owner_teleport_cooldown_ms, 0.0, 1500.0, "%.0f ms") then
    push_to_all_vehicles()
  end
  if imgui.SliderFloat("Remote teleport cooldown", remote_teleport_cooldown_ms, 0.0, 1500.0, "%.0f ms") then
    push_to_all_vehicles()
  end
  if imgui.SliderFloat("Teleport reset delay", teleport_reset_delay_ms, 0.0, 1500.0, "%.0f ms") then
    push_to_all_vehicles()
  end
end

M.draw = draw
M.push_to_vehicle = push_to_vehicle
M.push_to_all_vehicles = push_to_all_vehicles

return M
