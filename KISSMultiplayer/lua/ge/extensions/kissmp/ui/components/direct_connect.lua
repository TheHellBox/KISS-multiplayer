local gui = require("kissmp.ui.gui")
local imgui = gui.imgui
local inputs = require("kissmp.ui.global_inputs")
local config = require("kissmp.config")

local direct_address = imgui.ArrayChar(128)

local function draw_direct_connect()
  imgui.Text("Server address:")
  imgui.InputText("##addr", direct_address)
  imgui.SameLine()
  if imgui.Button("Connect") then
    local addr = ffi.string(direct_address)
    local player_name = ffi.string(inputs.player_name)
    config.config.name = player_name
    config.save_config()
    network.connect(addr, player_name)
  end
end

-- Direct Connection Component
local M = {}

local function onExtensionLoaded()
end

local function onUpdate(dt)
  draw_direct_connect()
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M