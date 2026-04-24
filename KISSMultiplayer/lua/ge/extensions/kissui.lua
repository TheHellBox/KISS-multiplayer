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
  tuning = require("kissmp.ui.tabs.tuning"),
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

local function clamp_scalar(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

-- TODO: Move all this somewhere else. Some of settings aren't even related to UI
M.addr = imgui.ArrayChar(128)
M.player_name = imgui.ArrayChar(32, "Unknown")
M.show_nametags = imgui.BoolPtr(true)
M.show_drivers = imgui.BoolPtr(true)
M.window_opacity = imgui.FloatPtr(0.8)
M.enable_view_distance = imgui.BoolPtr(true)
M.view_distance = imgui.IntPtr(300)

-- Sync tuning. Live-editable via the imgui Tuning tab; changes are
-- propagated to active vehicles via queueLuaCommand.
M.tuning = {
  path_strength = imgui.FloatPtr(1.0),
  heading_strength = imgui.FloatPtr(1.0),
  heading_hold = imgui.FloatPtr(1.0),
  cross_track_hold = imgui.FloatPtr(1.0),
  body_support = imgui.FloatPtr(1.0),
  noise_rejection = imgui.FloatPtr(1.0),
  yaw_prediction = imgui.BoolPtr(true),
}

function M.get_derived_sync_tuning()
  local t = M.tuning
  local path_strength = clamp_scalar(t.path_strength[0], 0.0, 3.0)
  local heading_strength = clamp_scalar(t.heading_strength[0], 0.0, 3.0)
  local heading_hold = clamp_scalar(t.heading_hold[0], 0.0, 3.0)
  local cross_track_hold = clamp_scalar(t.cross_track_hold[0], 0.0, 3.0)
  local body_support = clamp_scalar(t.body_support[0], 0.0, 3.0)
  local noise_rejection = clamp_scalar(t.noise_rejection[0], 0.0, 3.0)

  return {
    position_pull_gain = math.floor(30.0 * path_strength + 0.5),
    position_deadband = 0.01 * noise_rejection,
    velocity_deadband = 0.10 * noise_rejection,
    max_delta_v = 2.0 + (8.0 * path_strength),

    layer1_frame_planar_gain = 1.5 * path_strength,
    layer1_yaw_gain = 1.75 * heading_strength,
    layer1_yaw_rate_gain = 1.75 * heading_strength,
    layer1_support_gain = 0.35 * body_support,
    layer1_frame_planar_max_dv = 4.0 + (8.0 * path_strength),
    layer1_yaw_max_dv = 4.0 + (8.0 * heading_strength),

    layer1_heading_hold_yaw_trim_gain = 0.75 * heading_hold,
    layer1_cross_track_hold_gain = 0.75 * cross_track_hold,
    layer1_enable_yaw_prediction = t.yaw_prediction[0] and true or false,

    layer1_z_weight = 0.20 * body_support,
    layer1_tilt_weight = 0.15 * body_support,
    layer1_vz_weight = 0.25 * body_support,
    layer1_tilt_rate_weight = 0.20 * body_support,

    layer1_z_deadband = 0.03 * noise_rejection,
    layer1_tilt_deadband_deg = 1.5 * noise_rejection,
    layer1_vz_deadband = 0.15 * noise_rejection,
    layer1_tilt_rate_deadband = 0.15 * noise_rejection,

    layer1_shell_inset_cm = 8.0,
    layer1_debug_viz = false,
  }
end

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
  if M.tabs and M.tabs.tuning and M.tabs.tuning.onUpdate then
    M.tabs.tuning.onUpdate(dt)
  end
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
