local M = {}
local imgui = ui_imgui

local function generate_base_secret()
  math.randomseed(os.time() + os.clock())
  local result = ""
  for i=0,64 do
    local char = string.char(32 + math.random() * 96)
    result = result..char
  end
  return result
end

local function save_config()
  local secret = network.base_secret or "None"
  if secret == "None" then
    secret = generate_base_secret()
  end
  local result = {
    name = ffi.string(kissui.player_name),
    addr = ffi.string(kissui.addr),
    show_nametags = kissui.show_nametags[0],
    show_drivers = kissui.show_drivers[0],
    window_opacity = kissui.window_opacity[0],
    enable_view_distance = kissui.enable_view_distance[0],
    view_distance = kissui.view_distance[0],
    voice_range = kissui.voice_range[0],
    voice_input_volume = kissui.voice_input_volume[0],
    voice_input_device = kissui.voice_input_device or "",
    voice_curve_profile = kissui.voice_curve_profile or "Balanced",
    voice_player_volumes = kissui.voice_player_volumes or {},
    base_secret_v2 = secret
  }
  local file = io.open("./settings/kissmp_config.json", "w")
  file:write(jsonEncode(result))
  io.close(file)
end

local function load_config()
  local file = io.open("./settings/kissmp_config.json", "r")
  if not file then
    if Steam and Steam.isWorking and Steam.accountLoggedIn then
      kissui.player_name = imgui.ArrayChar(32, Steam.playerName)
    end
    return
  end
  local content = file:read("*a")
  local config = jsonDecode(content or "")
  if not config then return end

  if config.name ~= nil then
    kissui.player_name = imgui.ArrayChar(32, config.name)
  end
  if config.addr ~= nil then
    kissui.addr = imgui.ArrayChar(128, config.addr)
  end
  if config.show_nametags ~= nil then
    kissui.show_nametags[0] = config.show_nametags
  end
  if config.show_drivers ~= nil then
    kissui.show_drivers[0] = config.show_drivers
  end
  if config.window_opacity ~= nil then
    kissui.window_opacity[0] = config.window_opacity
  end
  if config.view_distance ~= nil then
    kissui.view_distance[0] = config.view_distance
  end
  if config.enable_view_distance ~= nil then
    kissui.enable_view_distance[0] = config.enable_view_distance
  end
  if config.base_secret_v2 ~= nil then
    network.base_secret = config.base_secret_v2
  end
  if config.voice_range ~= nil then
    kissui.voice_range[0] = tonumber(config.voice_range) or 120
  end
  if config.voice_input_volume ~= nil then
    kissui.voice_input_volume[0] = tonumber(config.voice_input_volume) or 1.0
  end
  if config.voice_input_device ~= nil then
    kissui.voice_input_device = tostring(config.voice_input_device)
  end
  if config.voice_curve_profile ~= nil then
    local profile = tostring(config.voice_curve_profile)
    if profile == "Realistic" or profile == "Balanced" or profile == "Arcade" then
      kissui.voice_curve_profile = profile
    else
      kissui.voice_curve_profile = "Balanced"
    end
  end
  if type(config.voice_player_volumes) == "table" then
    kissui.voice_player_volumes = {}
    for key, value in pairs(config.voice_player_volumes) do
      local id = tonumber(key)
      local volume = tonumber(value)
      if id and volume then
        kissui.voice_player_volumes[id] = volume
      end
    end
  end
  io.close(file)
end

local function init()
  load_config()
  if #FS:findFiles("/mods/", "kissmultiplayer.zip", 1000) == 0 then
    kissui.incorrect_install = true
  end
end

M.save_config = save_config
M.load_config = load_config
M.onExtensionLoaded = init

return M
