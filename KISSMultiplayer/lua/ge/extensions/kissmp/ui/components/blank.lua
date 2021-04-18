local gui = require("kissmp.ui.gui")
local imgui = gui.imgui

-- ^^^ Put drawing functions and such up here.

-- Blank component for example
local M = {}

local function onExtensionLoaded()
end

local function onUpdate(dt)
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M