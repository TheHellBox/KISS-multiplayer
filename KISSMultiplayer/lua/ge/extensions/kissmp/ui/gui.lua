-- Holds the imgui instance
local M = {}
local gui_module = require("ge/extensions/editor/api/gui")
local gui = {setupEditorGuiTheme = nop}
local imgui = ui_imgui

gui_module.initialize(gui)

M.meta = gui
M.imgui = imgui

return M