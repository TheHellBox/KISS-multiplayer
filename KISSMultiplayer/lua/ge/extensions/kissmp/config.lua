local M = {}
local imgui = ui_imgui

--- @class config
--- @field name string Player name
--- @field addr string Last address input
--- @field show_nametags boolean Show names above players
--- @field show_drivers boolean Show drivers inside player vehicles
--- @field window_opacity number Window opacity from 1-0
--- @field enable_view_distance boolean Vehicles outside `view_distance` are buffered
--- @field view_distance number Distance before vehicles outside the range are loaded in
local default_config = {
  name = "Unknown",
  addr = "",
  show_nametags = true,
  show_drivers = true,
  window_opacity = 0.8,
  enable_view_distance = true,
  view_distance = 300
}

--- @type config
local config = deepcopy(default_config)

local known_config_values = {}

for key, _ in pairs(default_config) do
  table.insert(known_config_values, key)
end

local function generate_base_secret()
  local result = ""
  for i=0,64 do
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
  local result = {}
  for _, key in ipairs(known_config_values) do
    result[key] = config[key]
  end
  result.base_secret = secret
  local file = io.open("./settings/kissmp_config.json", "w")
  file:write(jsonEncode(result))
  io.close(file)
end

local function load_config()
  local file = io.open("./settings/kissmp_config.json", "r")
  if not file then
    if Steam and Steam.isWorking and Steam.accountLoggedIn then
      config.name = imgui.ArrayChar(32, Steam.playerName)
    end
    return
  end
  local content = file:read("*a")
  local file_config = jsonDecode(content or "")
  if not file_config then return end
  for _, key in ipairs(known_config_values) do
    if file_config[key] ~= nil then
      config[key] = file_config[key]
    else
      config[key] = default_config[key]
    end
  end

  if file_config.base_secret ~= nil then
    network.base_secret = file_config.base_secret
  end

  io.close(file)
end

-- FIXME: Modularize network so this doesn't have to happen.
--load_config()
-- Hack to reload input actions
local actions = require("lua/ge/extensions/core/input/actions")
extensions.core_input_actions = actions
core_input_bindings.onFirstUpdate()

M.save_config = save_config
M.load_config = load_config
M.config = config

return M
