local M = {}
local imgui = ui_imgui

-- Receiver-side velocity smoothing rate (Hz cutoff) consumed by kiss_sync.lua.
-- Default must match kiss_sync.M.REMOTE_VEL_SMOOTH_RATE so the slider state
-- matches the vehicle-side state on first open.
local vel_rate = imgui.FloatPtr(2.0)
local prediction_offset_ms = imgui.FloatPtr(0.0)
local linear_pull_scale = imgui.FloatPtr(1.0)

local function build_command()
  return string.format(
    "kiss_sync.set_smoothing_tuning(%f, %f); kiss_transforms.set_linear_pull_scale(%f)",
    vel_rate[0],
    prediction_offset_ms[0] * 0.001,
    linear_pull_scale[0]
  )
end

local function push_to_vehicle(vehicle)
  if not vehicle then return end
  vehicle:queueLuaCommand(build_command())
end

local function push_to_all_vehicles()
  local cmd = build_command()
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
end

M.draw = draw
M.push_to_vehicle = push_to_vehicle
M.push_to_all_vehicles = push_to_all_vehicles

return M
