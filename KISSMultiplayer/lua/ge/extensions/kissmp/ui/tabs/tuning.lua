local M = {}
local imgui = ui_imgui

local function draw()
  imgui.PushTextWrapPos(0)
  imgui.Text("No live sync tuning is currently exposed.")
  imgui.Text("This tab is reserved for future cluster controls.")
  imgui.PopTextWrapPos()
end

M.draw = draw

return M
