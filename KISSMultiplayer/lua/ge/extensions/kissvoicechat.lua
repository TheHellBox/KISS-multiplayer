local M = {}
M.el = vec3(0.08, 0, 0)
M.er = vec3(-0.08, 0, 0)
M.is_talking = false

local function get_effective_frequency(frequency)
  local value = tonumber(frequency) or tonumber(kissui.voice_frequency[0]) or 0
  value = math.max(0, math.min(65535, math.floor(value)))
  if not kissui.voice_walkie_enabled[0] then
    return 0
  end
  return value
end

local function onUpdate()
  if not network.connection.connected then
    M.is_talking = false
    return
  end
  local position = vec3(getCameraPosition() or vec3())
  local ear_left = M.el:rotated(quat(getCameraQuat()))
  local ear_right = M.er:rotated(quat(getCameraQuat()))
  local pl = position + ear_left
  local pr = position + ear_right
  --debugDrawer:drawSphere((pl + vec3(0, 2, 0):rotated(quat(getCameraQuat()))):toPoint3F(), 0.05, ColorF(0,1,0,0.8))
  --debugDrawer:drawSphere((pr + vec3(0, 2, 0):rotated(quat(getCameraQuat()))):toPoint3F(), 0.05, ColorF(0,0,1,0.8))
  network.send_data({
      SpatialUpdate = {{pl.x, pl.y, pl.z}, {pr.x, pr.y, pr.z}}
  })
end

local function start_vc()
  M.is_talking = true
  network.send_data('"StartTalking"')
end


local function end_vc()
  M.is_talking = false
  network.send_data('"EndTalking"')
end

local function set_distance(value)
  network.send_data({ SetVoiceChatDistance = value })
end

local function set_player_volume(player_id, value)
  network.send_data({ SetVoiceChatPlayerVolume = { player_id, value } })
end

local function set_input_volume(value)
  network.send_data({ SetVoiceChatInputVolume = value })
end

local function set_input_device(device_name)
  network.send_data({ SetVoiceChatInputDevice = device_name or "" })
end

local function set_curve_profile(profile)
  network.send_data({ SetVoiceChatCurveProfile = profile or "Balanced" })
end

local function set_frequency(frequency)
  local value = get_effective_frequency(frequency)
  network.send_data({ SetVoiceChatFrequency = value }, true)
end

local function set_noise_suppression(enabled)
  network.send_data({ SetVoiceChatNoiseSuppression = enabled and true or false }, true)
end

local function set_echo_suppression(enabled)
  network.send_data({ SetVoiceChatEchoSuppression = enabled and true or false }, true)
end

local function set_noise_gate_strength(level)
  local value = tonumber(level) or 0.5
  value = math.max(0, math.min(1, value))
  network.send_data({ SetVoiceChatNoiseSuppressionLevel = value }, true)
end

local function set_echo_ducking_strength(level)
  local value = tonumber(level) or 0.8
  value = math.max(0, math.min(1, value))
  network.send_data({ SetVoiceChatEchoSuppressionLevel = value }, true)
end

-- Backwards compatibility aliases.
local set_noise_suppression_level = set_noise_gate_strength
local set_echo_suppression_level = set_echo_ducking_strength

local function get_tx_status()
  if not kissui.voice_walkie_enabled[0] then
    return "TX: Walkie OFF"
  end
  local frequency = get_effective_frequency(kissui.voice_frequency[0])
  if frequency == 0 then
    return "TX: No channel set"
  end
  if M.is_talking then
    return "TX: Channel " .. tostring(frequency) .. " (Sending)"
  end
  return "TX: Channel " .. tostring(frequency) .. " (Standby)"
end

local function get_rx_status()
  if not kissui.voice_walkie_enabled[0] then
    return "RX: Proximity only"
  end
  local frequency = get_effective_frequency(kissui.voice_frequency[0])
  if frequency == 0 then
    return "RX: Proximity only"
  end
  return "RX: Proximity + Channel " .. tostring(frequency)
end

local function request_input_devices()
  network.send_data('"RequestVoiceChatInputDevices"', true)
end

local function apply_settings()
  set_distance(kissui.voice_range[0])
  set_input_volume(kissui.voice_input_volume[0])
  set_input_device(kissui.voice_input_device)
  set_curve_profile(kissui.voice_curve_profile)
  set_frequency(kissui.voice_frequency[0])
  set_noise_suppression(kissui.voice_noise_suppression[0])
  set_echo_suppression(kissui.voice_echo_suppression[0])
  set_noise_gate_strength(kissui.voice_noise_gate_strength[0])
  set_echo_ducking_strength(kissui.voice_echo_ducking_strength[0])
  for player_id, volume in pairs(kissui.voice_player_volumes) do
    set_player_volume(player_id, volume)
  end
  request_input_devices()
end

M.onUpdate = onUpdate
M.start_vc = start_vc
M.end_vc = end_vc
M.set_distance = set_distance
M.set_player_volume = set_player_volume
M.set_input_volume = set_input_volume
M.set_input_device = set_input_device
M.set_curve_profile = set_curve_profile
M.set_frequency = set_frequency
M.set_noise_suppression = set_noise_suppression
M.set_echo_suppression = set_echo_suppression
M.set_noise_gate_strength = set_noise_gate_strength
M.set_echo_ducking_strength = set_echo_ducking_strength
M.set_noise_suppression_level = set_noise_suppression_level
M.set_echo_suppression_level = set_echo_suppression_level
M.get_tx_status = get_tx_status
M.get_rx_status = get_rx_status
M.request_input_devices = request_input_devices
M.apply_settings = apply_settings

return M
