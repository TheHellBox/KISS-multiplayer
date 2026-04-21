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
    base_secret_v2 = secret,
    tuning = {
      position_scale     = kissui.tuning.position_scale[0],
      velocity_scale     = kissui.tuning.velocity_scale[0],
      position_epsilon   = kissui.tuning.position_epsilon[0],
      velocity_epsilon   = kissui.tuning.velocity_epsilon[0],
      position_pull_gain = kissui.tuning.position_pull_gain[0],
      position_deadband  = kissui.tuning.position_deadband[0],
      velocity_deadband  = kissui.tuning.velocity_deadband[0],
      max_delta_v        = kissui.tuning.max_delta_v[0],
    },
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
  if config.tuning ~= nil then
    if config.tuning.position_scale ~= nil then
      kissui.tuning.position_scale[0] = config.tuning.position_scale
    end
    if config.tuning.velocity_scale ~= nil then
      kissui.tuning.velocity_scale[0] = config.tuning.velocity_scale
    end
    if config.tuning.position_epsilon ~= nil then
      kissui.tuning.position_epsilon[0] = config.tuning.position_epsilon
    end
    if config.tuning.velocity_epsilon ~= nil then
      kissui.tuning.velocity_epsilon[0] = config.tuning.velocity_epsilon
    end
    if config.tuning.position_pull_gain ~= nil then
      kissui.tuning.position_pull_gain[0] = config.tuning.position_pull_gain
    end
    if config.tuning.position_deadband ~= nil then
      kissui.tuning.position_deadband[0] = config.tuning.position_deadband
    end
    if config.tuning.velocity_deadband ~= nil then
      kissui.tuning.velocity_deadband[0] = config.tuning.velocity_deadband
    end
    if config.tuning.max_delta_v ~= nil then
      kissui.tuning.max_delta_v[0] = config.tuning.max_delta_v
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
