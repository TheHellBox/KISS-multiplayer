local gui = require("kissmp.ui.gui")
local imgui = gui.imgui
local c = require("kissmp.config")
local show_nametags = imgui.BoolPtr(true)
local show_drivers = imgui.BoolPtr(true)
local window_opacity = imgui.FloatPtr(0.8)
local enable_view_distance = imgui.BoolPtr(true)
local view_distance = imgui.IntPtr(300)

local function init_settings()
  show_nametags[0] = c.config.show_nametags
  show_drivers[0] = c.config.show_drivers
  window_opacity[0] = c.config.window_opacity
  enable_view_distance[0] = c.config.enable_view_distance
  view_distance[0] = c.config.view_distance
end

local function draw_settings() 
  if imgui.Checkbox("Show Name Tags", show_nametags) then
    c.config.show_nametags = show_nametags[0]
    c.save_config()
  end
  if imgui.Checkbox("Show Players In Vehicles", show_drivers) then
    c.config.show_drivers = show_drivers[0]
    c.save_config()
  end
  imgui.Text("Window Opacity")
  imgui.SameLine()
  if imgui.SliderFloat("###window_opacity", window_opacity, 0, 1) then
    c.config.window_opacity = window_opacity[0]
    c.save_config()
  end
  if imgui.Checkbox("Enable view distance (Experimental)", enable_view_distance) then
    c.config.enable_view_distance = enable_view_distance[0]
    c.save_config()
  end
  if enable_view_distance[0] then
    if imgui.SliderInt("###view_distance", view_distance, 50, 1000) then
      c.config.view_distance = view_distance[0]
      c.save_config()
    end
    imgui.PushTextWrapPos(0)
    imgui.Text("Warning. This feature is experimental. It can introduce a small, usually unnoticeable lag spike when approaching nearby vehicles. It'll also block the ability to switch to far away vehicles")
    imgui.PopTextWrapPos()
  end
end

-- Settings Component
local M = {}

local function onExtensionLoaded()
  init_settings()
end

local function onUpdate(dt)
  draw_settings()
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M