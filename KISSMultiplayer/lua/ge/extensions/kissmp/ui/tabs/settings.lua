local M = {}
local imgui = ui_imgui

local function draw()
  if imgui.Checkbox("Show Name Tags", kissui.show_nametags) then
    kissconfig.save_config()
  end
  if imgui.Checkbox("Show Players In Vehicles", kissui.show_drivers) then
    kissconfig.save_config()
  end
  imgui.Text("Window Opacity")
  imgui.SameLine()
  if imgui.SliderFloat("###window_opacity", kissui.window_opacity, 0, 1) then
    kissconfig.save_config()
  end
  imgui.Text("Warning. This feature will not work when docked due to ImGui")
  if imgui.Checkbox("Enable view distance (Experimental)", kissui.enable_view_distance) then
    kissconfig.save_config()
  end
  if kissui.enable_view_distance[0] then
    if imgui.SliderInt("###view_distance", kissui.view_distance, 50, 1000) then
      kissconfig.save_config()
    end
    imgui.PushTextWrapPos(0)
    imgui.Text("Warning. This feature is experimental. It can introduce a small, usually unnoticeable lag spike when approaching nearby vehicles. It'll also block the ability to switch to far away vehicles")
    imgui.PopTextWrapPos()
  end
end

M.draw = draw

return M
