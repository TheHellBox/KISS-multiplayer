local M = {}
local im = ui_imgui

local red_color = im.ImVec4(0.9, 0, 0, 1)
local mouse_cursor_pos = im.ImVec2(0, 0)
local config_items = {}

local confirm_popup_active = false
local confirm_player_name = im.ArrayChar(32, "")
local confirm_timer = 5

local fade_distance_name = ""
local fade_distances = {
  {"Near", 50},
  {"Balanced", 100},
  {"Far", 250},
  {"Very Far", 400}
}

local view_distance_name = ""
local view_distances = {
  {"Near", 150},
  {"Balanced", 300},
  {"Far", 450},
  {"Very Far", 600}
}

local function render_checkbox(ui_name, setting_id)
  local checkbox_name = "###"..setting_id
  if ui_name then
    checkbox_name = ui_name..checkbox_name
  end
  if im.Checkbox(checkbox_name, config_items[setting_id]) then
    kissconfig.set_setting(setting_id, config_items[setting_id][0])
  end
end

local function render_sliderF(ui_name, setting_id,  min, max, format)
  format = format or "%.1f"
  local slider_name = "###"..setting_id
  if ui_name then
    slider_name = ui_name..slider_name
  end
  if im.SliderFloat(slider_name, config_items[setting_id], min, max, format) then
    kissconfig.set_setting(setting_id, config_items[setting_id][0])
  end
end

local function render_sliderI(ui_name, setting_id, min, max, format)
  local slider_name = "###"..setting_id
  if ui_name then
    slider_name = ui_name..slider_name
  end
  if im.SliderInt(slider_name, config_items[setting_id], min, max, format) then
    kissconfig.set_setting(setting_id, config_items[setting_id][0])
  end
end

local function help_marker(text, desc)
  im.TextDisabled(text)
  if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) and im.BeginTooltip() then
    im.PushTextWrapPos(im.GetFontSize() * 35.0);
    im.TextUnformatted(desc);
    im.PopTextWrapPos();
    im.EndTooltip();
  end
end

local function draw(dt)
  im.Text("User Interface")
  im.Separator()
  render_sliderF("UI scale", "ui.scale", 0.9, 2)
  render_sliderF("Window opacity", "ui.window_opacity", 0.3, 1)

  im.NewLine()
  im.Text("Player Visibility")
  im.Separator()
  render_checkbox("Show players in vehicles", "players.show_drivers")
  im.NewLine()
  render_checkbox("Show name tags", "players.show_nametags")
  render_checkbox("Use player colours in name tags", "players.nametags.colorful")
  render_checkbox(nil, "players.nametags.fade")
  local slider_active = config_items["players.nametags.fade"][0]
  if not slider_active then
    im.BeginDisabled()
  end
  im.SameLine()
  local cursorX = im.GetCursorPosX()
  local distance = config_items["players.nametags.fade"][0]
  im.SetNextItemWidth(im.CalcTextSize(fade_distance_name).x+im.GetTextLineHeight()+im.GetStyle().FramePadding.x*4)
  if im.BeginCombo("Fade name tags based on distance", fade_distance_name) then
    for _, v in ipairs(fade_distances) do
      if im.Selectable1(string.format("%s (%dm)", v[1], v[2]), fade_distance_name == v[1]) then
        distance = v[2]
        kissconfig.set_setting("players.nametags.fade_start_distance", distance)
        fade_distance_name = v[1]
      end
    end
    if im.Selectable1("Custom", fade_distance_name == "Custom") then
      fade_distance_name = "Custom"
    end
    im.EndCombo()
  end
  if fade_distance_name == "Custom" then
    im.SetCursorPosX(cursorX)
    render_sliderI("##players.nametags.fade_start_distance", "players.nametags.fade_start_distance", 25, 500, "%dm")
  end
  if not slider_active then
    im.EndDisabled()
  end
  render_checkbox("Hide name tags behind objects", "players.nametags.use_z")

  im.NewLine()
  im.Text("Performance")
  im.Separator()
  render_checkbox(nil, "perf.enable_view_distance")
  local slider_active = config_items["perf.enable_view_distance"][0]
  if not slider_active then
    im.BeginDisabled()
  end
  im.SameLine()
  local cursorX = im.GetCursorPosX()
  local distance = config_items["perf.view_distance"][0]
  im.SetNextItemWidth(im.CalcTextSize(view_distance_name).x+im.GetTextLineHeight()+im.GetStyle().FramePadding.x*4)
  if im.BeginCombo("Limit vehicle view distance", view_distance_name) then
    for _, v in ipairs(view_distances) do
      if im.Selectable1(string.format("%s (%dm)", v[1], v[2]), view_distance_name == v[1]) then
        distance = v[2]
        kissconfig.set_setting("perf.view_distance", distance)
        view_distance_name = v[1]
      end
    end
    if im.Selectable1("Custom", view_distance_name == "Custom") then
      view_distance_name = "Custom"
    end
    im.EndCombo()
  end
  im.SameLine()

  if not slider_active then
    im.EndDisabled()
  end
  help_marker("[?]", [[Experimental:
  This may introduce a minor lag spike when approaching vehicles.
  It also prevents you from switching to vehicles currently outside your view distance.]])
  if not slider_active then
    im.BeginDisabled()
  end

  if view_distance_name == "Custom" then
    im.SetCursorPosX(cursorX)
    render_sliderI("##perf.view_distance", "perf.view_distance", 50, 1000, "%dm")
  end
  im.SetCursorPosX(cursorX)
  im.PushTextWrapPos(0)
  im.PopTextWrapPos()
  if not slider_active then
    im.EndDisabled()
  end

  im.PushStyleColor2(im.Col_Text, red_color)
  im.NewLine()
  im.Text("Danger Zone")
  im.Separator()
  if im.Checkbox("Allow public servers to run commands", config_items["security.public_scripting"]) then
    if config_items["security.public_scripting"][0] then
      im.OpenPopup1("SecurityConfirmationPopup")
      mouse_cursor_pos = im.GetMousePos()
      confirm_popup_active = true
    else
      kissconfig.set_setting("security.public_scripting", false)
    end
  end
  if im.Checkbox("Allow public servers to install mods", config_items["security.public_mods"]) then
    if config_items["security.public_mods"][0] then
      im.OpenPopup1("SecurityConfirmationPopup")
      mouse_cursor_pos = im.GetMousePos()
      confirm_popup_active = true
    else
      kissconfig.set_setting("security.public_mods", false)
    end
  end
  im.PopStyleColor()

  im.SetNextWindowPos(mouse_cursor_pos, im.Cond_Always, im.ImVec2(0, 0))
  if im.BeginPopup("SecurityConfirmationPopup") then
    im.Text("Servers can infect your computer.")
    im.Text("Servers can steal your data.")
    im.Text("ONLY USE PUBLIC SERVERS YOU TRUST.")
    im.NewLine()

    if confirm_timer > 0 then
      confirm_timer = confirm_timer - dt
    end
    local cant_use = confirm_timer > 0
    if cant_use then
      im.BeginDisabled()
      im.Text("("..math.ceil(confirm_timer)..") Enter your player name to continue:")
    else
      im.Text("Enter your player name to continue:")
    end
    if im.InputText("##name", confirm_player_name) then
      if ffi.string(confirm_player_name) == ffi.string(kissui.player_name) then
        kissconfig.set_setting("security.public_scripting", config_items["security.public_scripting"][0])
        kissconfig.set_setting("security.public_mods", config_items["security.public_mods"][0])
        ffi.copy(confirm_player_name, "")
        confirm_timer = 5
        confirm_popup_active = false
        im.CloseCurrentPopup()
      end
    end
    if cant_use then
      im.EndDisabled()
    end

    im.EndPopup()
  elseif confirm_popup_active then -- user closed it
    config_items["security.public_scripting"][0] = kissconfig.get_setting("security.public_scripting")
    config_items["security.public_mods"][0] = kissconfig.get_setting("security.public_mods")
    ffi.copy(confirm_player_name, "")
    confirm_timer = 5
    confirm_popup_active = false
  end
end

local function onKissMPSettingsChanged(config)
  config_items["ui.scale"] = im.FloatPtr(config["ui.scale"])
  config_items["ui.window_opacity"] = im.FloatPtr(config["ui.window_opacity"])

  config_items["players.show_nametags"] = im.BoolPtr(config["players.show_nametags"])
  config_items["players.show_drivers"] = im.BoolPtr(config["players.show_drivers"])

  config_items["players.nametags.fade"] = im.BoolPtr(config["players.nametags.fade"])
  config_items["players.nametags.fade_start_distance"] = im.IntPtr(config["players.nametags.fade_start_distance"])

  -- this will stop the entire widget changing away from custom whenever a distance matches a preset
  -- but ONLY between game sessions, restarting the game will make it use an actual preset if applicable
  if fade_distance_name ~= "Custom" then
    local distance = config["players.nametags.fade_start_distance"]
    for _, v in ipairs(fade_distances) do
      if distance == v[2] then
        fade_distance_name = v[1]
        goto break_loop
      end
    end
    fade_distance_name = "Custom"
    ::break_loop::
  end

  config_items["players.nametags.colorful"] = im.BoolPtr(config["players.nametags.colorful"])
  config_items["players.nametags.use_z"] = im.BoolPtr(config["players.nametags.use_z"])

  config_items["perf.enable_view_distance"] = im.BoolPtr(config["perf.enable_view_distance"])
  config_items["perf.view_distance"] = im.IntPtr(config["perf.view_distance"])

  if view_distance_name ~= "Custom" then
    local distance = config["perf.view_distance"]
    for _, v in ipairs(view_distances) do
      if distance == v[2] then
        view_distance_name = v[1]
        goto break_loop
      end
    end
    view_distance_name = "Custom"
    ::break_loop::
  end

  if not confirm_popup_active then
    config_items["security.public_scripting"] = im.BoolPtr(config["security.public_scripting"])
    config_items["security.public_mods"] = im.BoolPtr(config["security.public_mods"])
  end
end

M.draw = draw
M.onKissMPSettingsChanged = onKissMPSettingsChanged

return M
