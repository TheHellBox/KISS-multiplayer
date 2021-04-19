-- Main UI
local M = {}
local config = require("kissmp.config")
local gui = require("kissmp.ui.gui")
local inputs = require("kissmp.ui.global_inputs")
local servers_ui = require("kissmp.ui.components.servers")
local direct_ui = require("kissmp.ui.components.direct_connect")
local settings_ui = require("kissmp.ui.components.settings")
local download_ui = require("kissmp.ui.components.download")
local chat_ui = require("kissmp.ui.components.chat")
local chat = require("kissmp.chat")
local add_favorite_ui = require("kissmp.ui.components.direct_favorite_add")
-- TODO: Register windows in a neat way.
local all_ui = {
  servers_ui,
  direct_ui,
  settings_ui,
  download_ui,
  chat_ui,
  add_favorite_ui
}
local draw_names = require("kissmp.ui.draw_names")
local install_check = require("kissmp.install_check")
local bor = bit.bor
local imgui = gui.imgui
local gm = gui.meta
local ui_showing = false
local window_flags = {
  no_scroll = imgui.WindowFlags_NoScrollbar,
  no_resize = imgui.WindowFlags_NoResize,
  auto_size = imgui.WindowFlags_AlwaysAutoResize
}

local function setup_ui()
  for _, ui in ipairs(all_ui) do
    ui.onExtensionLoaded()
  end
  gm.registerWindow("KissMP", imgui.ImVec2(256, 256))
  gm.registerWindow("Chat", imgui.ImVec2(256, 256))
  gm.registerWindow("Downloads", imgui.ImVec2(512, 512))
  gm.registerWindow("Add Favorite", imgui.ImVec2(256, 128))
  gm.registerWindow("Incorrect install detected", imgui.ImVec2(256, 128))
  gm.hideWindow("Add Favorite")
end

local function show_ui()
  -- TODO: Window registeration
  for _, window in ipairs({"KissMP", "Chat", "Downloads"}) do
    gm.showWindow(window)
  end
  ui_showing = true
end

local function hide_ui()
  -- TODO: Window registeration
  for _, window in ipairs({"KissMP", "Chat", "Downloads", "Add Favorite"}) do
    gm.showWindow(window)
  end
  ui_showing = false
end

local function toggle_ui()
  if ui_showing then
    hide_ui()
  else
    show_ui()
  end
end

local function draw_main_window(dt)
  if network.downloading then return end
  if not gm.isWindowVisible("KissMP") then return end

  imgui.SetNextWindowBgAlpha(config.config.window_opacity)
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 300))
  imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
  if imgui.Begin("KissMP") then
    imgui.Text("Player name:")
    imgui.InputText("##name", inputs.player_name)
    if network.connection.connected then
      if imgui.Button("Disconnect") then
        network.disconnect()
      end
    end
   
    imgui.Dummy(imgui.ImVec2(0, 5))

    if imgui.BeginTabBar("server_tabs##") then
      if imgui.BeginTabItem("Server List") then
        servers_ui.onUpdate(dt, false)
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Direct Connect") then
        direct_ui.onUpdate(dt)
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Favorites") then
        servers_ui.onUpdate(dt, true)
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Settings") then
        settings_ui.onUpdate(dt)
        imgui.EndTabItem()
      end
      imgui.EndTabBar()
    end
  end
  imgui.End()
end

local function draw_chat_window(dt)
  if not gm.isWindowVisible("Chat") then return end
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 300))
  local window_title = "Chat"
  if chat.unread_message_count > 0 then
    window_title = window_title .. " (" .. tostring(chat_ui.unread_message_count) .. ")"
  end
  window_title = window_title .. "###chat"
  
  imgui.SetNextWindowBgAlpha(config.config.window_opacity)
  imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
  if imgui.Begin(window_title) then
    chat_ui.onUpdate(dt)
  end
  imgui.End()
end

local function draw_download_window(dt)
  if not network.downloading then return end
  if not gm.isWindowVisible("Downloads") then return end
  
  imgui.SetNextWindowBgAlpha(config.config.window_opacity)
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 300))
  imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
  if imgui.Begin("Downloading Required Mods") then
    download_ui.onUpdate(dt)
  end

  imgui.End()
end

local function draw_add_favorite_window(dt)
  if not gm.isWindowVisible("Add Favorite") then return end
  local display_size = imgui.GetIO().DisplaySize

  imgui.SetNextWindowPos(
    imgui.ImVec2(display_size.x / 2, display_size.y / 2),
    imgui.Cond_Always,
    imgui.ImVec2(0.5, 0.5)
  )
  imgui.SetNextWindowBgAlpha(config.config.window_opacity)
  if imgui.Begin(
    "Add Favorite",
    gui.getWindowVisibleBoolPtr("Add Favorite"),
    bor(
      window_flags.no_scroll,
      window_flags.no_resize,
      window_flags.auto_size
    )
  ) then
    add_favorite_ui.onUpdate(dt)
  end
  imgui.End()
end

local function draw_incorrect_install_window(dt)
  if install_check and false then return end -- TODO: Remove this
  if imgui.Begin("Incorrect install detected") then
    imgui.Text("Incorrect KissMP install. Please, check if mod path is correct")
  end
  imgui.End()
end

local function onExtensionLoaded()
  -- FIXME: Remove this after network is modularized
  config.load_config()
  inputs.player_name = imgui.ArrayChar(32, config.config.name)
  setup_ui()
  show_ui()
end

local function onUpdate(dt)
  if getMissionFilename() ~= '' and not vehiclemanager.is_network_session then
    return
  end
  draw_main_window(dt)
  draw_chat_window(dt)
  draw_add_favorite_window(dt)
  draw_incorrect_install_window(dt)
  draw_download_window(dt)
  if not M.force_disable_nametags and config.config.show_nametags then
    draw_names(dt)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.show_ui = show_ui
M.hide_ui = hide_ui
M.toggle_ui = toggle_ui
M.force_disable_nametags = false

return M