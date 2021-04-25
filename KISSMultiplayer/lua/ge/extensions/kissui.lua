local M = {}
local http = require("socket.http")

local bor = bit.bor

local main_window = require("kissmp.ui.main")
M.chat = require("kissmp.ui.chat")
M.download_window = require("kissmp.ui.download")
local names = require("kissmp.ui.names")

M.tabs = {
  server_list = require("kissmp.ui.tabs.server_list"),
  favorites = require("kissmp.ui.tabs.favorites"),
  settings = require("kissmp.ui.tabs.settings"),
  direct_connect = require("kissmp.ui.tabs.direct_connect"),
  create_server = require("kissmp.ui.tabs.create_server"),
}

M.dependencies = {"ui_imgui"}

M.master_addr = "http://kissmp.online:3692/"
M.bridge_launched = false

M.show_download = false
M.downloads_info = {}

-- Color constants
M.COLOR_YELLOW = {r = 1, g = 1, b = 0}
M.COLOR_RED = {r = 1, g = 0, b = 0}

M.force_disable_nametags = false

local gui_module = require("ge/extensions/editor/api/gui")
M.gui = {setupEditorGuiTheme = nop}
local imgui = ui_imgui

local ui_showing = false

-- TODO: Move all this somewhere else. Some of settings aren't even related to UI
M.addr = imgui.ArrayChar(128)
M.player_name = imgui.ArrayChar(32, "Unknown")
M.show_nametags = imgui.BoolPtr(true)
M.show_drivers = imgui.BoolPtr(true)
M.window_opacity = imgui.FloatPtr(0.8)
M.enable_view_distance = imgui.BoolPtr(true)
M.view_distance = imgui.IntPtr(300)

local function show_ui()
  M.gui.showWindow("KissMP")
  M.gui.showWindow("Chat")
  M.gui.showWindow("Downloads")
  ui_showing = true
end

local function hide_ui()
  M.gui.hideWindow("KissMP")
  M.gui.hideWindow("Chat")
  M.gui.hideWindow("Downloads")
  M.gui.hideWindow("Add Favorite")
  ui_showing = false
end

local function toggle_ui()
  if not ui_showing then
    show_ui()
  else
    hide_ui()
  end
end

local function open_ui()
  main_window.init(M)
  gui_module.initialize(M.gui)
  M.gui.registerWindow("KissMP", imgui.ImVec2(256, 256))
  M.gui.registerWindow("Chat", imgui.ImVec2(256, 256))
  M.gui.registerWindow("Downloads", imgui.ImVec2(512, 512))
  M.gui.registerWindow("Add Favorite", imgui.ImVec2(256, 128))
  M.gui.registerWindow("Incorrect install detected", imgui.ImVec2(256, 128))
  M.gui.hideWindow("Add Favorite")
  show_ui()
end

local function bytes_to_mb(bytes)
  return (bytes / 1024) / 1024
end

local function draw_incorrect_install()
  if imgui.Begin("Incorrect install detected") then
    imgui.Text("Incorrect KissMP install. Please, check if mod path is correct")
  end
  imgui.End()
end

local function onUpdate(dt)
  if getMissionFilename() ~= '' and not vehiclemanager.is_network_session then
    return
  end
  main_window.draw(dt)
  M.chat.draw()
  M.download_window.draw()
  if M.incorrect_install then
     draw_incorrect_install()
  end
  if (not M.force_disable_nametags) and M.show_nametags[0] then
    names.draw()
  end
end

M.onExtensionLoaded = open_ui
M.onUpdate = onUpdate

-- Backwards compatability
M.add_message = M.chat.add_message
M.draw_download = M.download_window.draw

M.show_ui = show_ui
M.hide_ui = hide_ui
M.toggle_ui = toggle_ui

return M
