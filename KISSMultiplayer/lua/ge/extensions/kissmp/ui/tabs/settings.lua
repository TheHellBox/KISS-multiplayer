local M = {}
local imgui = ui_imgui
local player_volume_ptrs = {}

local function draw_voice_settings()
  imgui.Separator()
  imgui.Text("Voice Chat")

  if imgui.SliderFloat("Range###voice_range", kissui.voice_range, 5, 1000) then
    kissconfig.save_config()
    kissvoicechat.set_distance(kissui.voice_range[0])
  end

  if imgui.BeginCombo("Distance Curve###voice_curve_profile", kissui.voice_curve_profile or "Balanced") then
    for i, profile in ipairs(kissui.voice_curve_profiles or {}) do
      local selected = (kissui.voice_curve_profile == profile)
      if imgui.Selectable1(tostring(profile) .. "###voice_curve_profile_" .. i, selected) then
        kissui.voice_curve_profile = tostring(profile)
        kissconfig.save_config()
        kissvoicechat.set_curve_profile(kissui.voice_curve_profile)
      end
    end
    imgui.EndCombo()
  end

  if imgui.SliderFloat("Microphone Input Volume###voice_input_volume", kissui.voice_input_volume, 0, 3) then
    kissconfig.save_config()
    kissvoicechat.set_input_volume(kissui.voice_input_volume[0])
  end

  local device_preview = kissui.voice_input_device
  if device_preview == "" then
    device_preview = "Default"
  end

  if imgui.BeginCombo("Input Device###voice_input_device", device_preview) then
    if imgui.Selectable1("Default###voice_input_device_default", kissui.voice_input_device == "") then
      kissui.voice_input_device = ""
      kissconfig.save_config()
      kissvoicechat.set_input_device("")
    end
    for i, device_name in ipairs(kissui.voice_input_devices) do
      local selected = (kissui.voice_input_device == device_name)
      if imgui.Selectable1(tostring(device_name) .. "###voice_input_device_" .. i, selected) then
        kissui.voice_input_device = tostring(device_name)
        kissconfig.save_config()
        kissvoicechat.set_input_device(kissui.voice_input_device)
      end
    end
    imgui.EndCombo()
  end

  if imgui.Button("Refresh Input Devices") then
    kissvoicechat.request_input_devices()
  end

  imgui.Separator()
  imgui.Text("Volume Per Player")
  if not network.connection.connected then
    imgui.Text("Connect to a server to adjust player voice volume")
    return
  end

  local ids = {}
  local self_id = network.get_client_id()
  for player_id, _ in pairs(network.players) do
    if player_id ~= self_id then
      table.insert(ids, player_id)
    end
  end
  table.sort(ids)

  if #ids == 0 then
    imgui.Text("No other players connected")
  end

  local visible_ids = {}
  for _, player_id in ipairs(ids) do
    visible_ids[player_id] = true
    local info = network.players[player_id] or {}
    local player_name = info.name or ("Player " .. tostring(player_id))
    local current_value = kissui.voice_player_volumes[player_id] or 1.0
    local ptr = player_volume_ptrs[player_id]
    if not ptr then
      ptr = imgui.FloatPtr(current_value)
      player_volume_ptrs[player_id] = ptr
    else
      ptr[0] = current_value
    end

    if imgui.SliderFloat(player_name .. "###voice_player_volume_" .. tostring(player_id), ptr, 0, 3) then
      local value = ptr[0]
      kissui.voice_player_volumes[player_id] = value
      kissconfig.save_config()
      kissvoicechat.set_player_volume(player_id, value)
    end
  end

  for player_id, _ in pairs(player_volume_ptrs) do
    if not visible_ids[player_id] then
      player_volume_ptrs[player_id] = nil
    end
  end
end

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

  draw_voice_settings()
end

M.draw = draw

return M
