local M = {}
local imgui = ui_imgui

local function generate_base_secret()
  local result = ""
  for i=0,10 do
    local char = string.char(32 + math.random() * 96)
    result = result..char
  end
  return result
end

local function save_config()
  local secret = network.base_secret
  if secret == "None" then
    secret = generate_base_secret()
  end
  local result = {
    name = ffi.string(kissui.player_name),
    addr = ffi.string(kissui.addr),
    show_nametags = kissui.show_nametags[0],
    window_opacity = kissui.window_opacity[0],
    base_secret = secret
  }
  local file = io.open("./kissmp_config.json", "w")
  file:write(jsonEncode(result))
  io.close(file)
end

local function load_config()
  local file = io.open("./kissmp_config.json", "r")
  if not file then
    if Steam and Steam.isWorking and Steam.accountLoggedIn then
      player_name = imgui.ArrayChar(32, Steam.playerName)
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
  if config.window_opacity ~= nil then
    kissui.window_opacity[0] = config.window_opacity
  end
  if config.base_secret ~= nil then
    network.base_secret = config.base_secret
  end
  io.close(file)
end

local function init()
  load_config()
  if not FS:fileExists("/mods/KISSMultiplayer.zip") then
    kissui.incorrect_install = true
  end
end

M.save_config = save_config
M.load_config = load_config
M.onExtensionLoaded = init

return M
