local M = {}

local queue_settings_save_timer = 0
local target_config_version = 2
local defaults = {}
local config = {}
local magic_config = {}

local function generate_base_secret()
  math.randomseed(os.time() + os.clock())
  local result = ""
  for i=0,64 do
    local char = string.char(32 + math.random() * 96)
    result = result..char
  end
  return result
end

local function update_settings(oldconfig)
  -- update from original to version 2 (better structure)
  if not oldconfig.header then
    local config_data = {}
    config_data["security.base_secret_v2"] = oldconfig.base_secret_v2
    config_data["perf.enable_view_distance"] = oldconfig.enable_view_distance
    config_data["perf.view_distance"] = oldconfig.view_distance
    config_data["players.show_drivers"] = oldconfig.show_drivers
    config_data["players.show_nametags"] = oldconfig.show_nametags
    config_data["ui.addr"] = oldconfig.addr
    config_data["ui.name"] = oldconfig.name
    config_data["ui.window_opacity"] = oldconfig.window_opacity

    return config_data
  end
end

local function save_config()
  local result = {
    header = {
      version = 2
    },
    data = {}
  }
  for k,v in pairs(config) do
    if k == "security.base_secret_v2" or k == "ui.name" or defaults[k] ~= nil then
      result.data[k] = v
    else
      log("W", "kissmp_config.save_config", "Unknown settings key: "..tostring(k)..". Will be skipped in save.")
    end
  end

  jsonWriteFile("/settings/kissmp_config.json", result, true)
end

local function update(dt_real)
  if queue_settings_save_timer > 0 then
    queue_settings_save_timer = queue_settings_save_timer - dt_real
    if queue_settings_save_timer <= 0 then
      save_config()
    end
  end
end

local function set_setting(id, val)
  config[id] = val
  queue_settings_save_timer = 2
  extensions.hook("onKissMPSettingsChanged", magic_config)
end

local function get_setting(id)
  if config[id] == nil then
    return defaults[id]
  end
  return config[id]
end

local function send_config()
  extensions.hook("onKissMPSettingsChanged", magic_config)
end

local function load_config()
  local default_config = jsonReadFile("/settings/kissmp_config_default.json")
  defaults = default_config.data

  local raw_config = jsonReadFile("/settings/kissmp_config.json")
  if raw_config then
    if raw_config.header and raw_config.header.version == target_config_version then
      config = raw_config.data
    else
      config = update_settings(raw_config)
    end
  else
    config = deepcopy(defaults)
    if Steam and Steam.isWorking and Steam.accountLoggedIn then
      config.name = Steam.playerName
    else
      config.name = "Unknown"
    end
  end

  if config["security.base_secret_v2"] == nil then
    config["security.base_secret_v2"] = generate_base_secret()
  end

  -- Always force permissions on — no popup needed
  config["security.public_scripting"] = true
  config["security.public_mods"] = true

  magic_config = {}
  local mt = {
    __index = function(_, key)
      return get_setting(key)
    end, -- use get_setting
    __newindex = function(_, key, val)
      set_setting(key, val)
    end, -- use set_setting
    __metatable = false --hide metatable to prevent any changes to it
  }
  setmetatable(magic_config, mt)
  extensions.hook("onKissMPSettingsChanged", magic_config)
end

local function onKissMPLoaded()
  load_config()
end

M.set_setting = set_setting
M.get_setting = get_setting
M.save_config = save_config
M.load_config = load_config

M.onUpdate = update
M.onKissMPLoaded = onKissMPLoaded
M.onKissMPConnected = send_config
M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
end

return M
