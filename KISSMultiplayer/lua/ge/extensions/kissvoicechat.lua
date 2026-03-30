local M = {}
M.el = vec3(0.08, 0, 0)
M.er = vec3(-0.08, 0, 0)

local function onUpdate()
  if not network.connection.connected then return end
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
  network.send_data('"StartTalking"')
end


local function end_vc()
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

local function request_input_devices()
  network.send_data('"RequestVoiceChatInputDevices"', true)
end

local function apply_settings()
  set_distance(kissui.voice_range[0])
  set_input_volume(kissui.voice_input_volume[0])
  set_input_device(kissui.voice_input_device)
  set_curve_profile(kissui.voice_curve_profile)
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
M.request_input_devices = request_input_devices
M.apply_settings = apply_settings

return M
