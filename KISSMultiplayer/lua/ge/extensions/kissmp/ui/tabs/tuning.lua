local M = {}
local imgui = ui_imgui

-- Receiver-side velocity smoothing rate (Hz cutoff) consumed by kiss_sync.lua.
-- Default must match kiss_sync.M.REMOTE_VEL_SMOOTH_RATE so the slider state
-- matches the vehicle-side state on first open.
local vel_rate = imgui.FloatPtr(8.0)

local function build_command()
  return string.format(
    "kiss_sync.set_smoothing_tuning(%f)",
    vel_rate[0]
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
end

M.draw = draw
M.push_to_vehicle = push_to_vehicle
M.push_to_all_vehicles = push_to_all_vehicles

return M
