local M = {}
local imgui = ui_imgui
local http = require("socket.http")

M.map = "/levels/industrial/info.json"
M.map_name = "industrial"
M.mods = {""}
M.server_name = imgui.ArrayChar(128, "Private KissMP server")
M.max_players = imgui.IntPtr(8)
M.port = imgui.IntPtr(3698)

local function host_server()
  local port = M.port[0]
  local mods_converted = {}
  for k, v in pairs(M.mods) do
    table.insert(mods_converted, v)
  end
  local config = {
    name = ffi.string(M.server_name),
    max_players = M.max_players[0],
    map = M.map,
    mods = mods_converted,
    port = port
  }
  local b, _, _  = http.request("http://127.0.0.1:3693/host/"..jsonEncode(config))
  if b == "ok" then
    local player_name = ffi.string(kissui.player_name)
    network.connect("127.0.0.1:"..port, player_name)
  end
end

local function draw()
  imgui.Text("Server name:")
  imgui.InputText("##host_server_name", M.server_name)
  imgui.Text("Max players:")
  imgui.InputInt("###host_max_players", M.max_players)
  imgui.Text("Map:")
  if imgui.BeginCombo("###host_map", M.map_name) then
    for k, v in pairs(core_levels.getList()) do
      if imgui.Selectable1(v.levelName.."###host_map_s_"..k) then
        local map_path = v.misFilePath.."info.json"
        M.map = map_path
        M.map_name = v.levelName
      end
    end
    imgui.EndCombo()
  end
  imgui.Text("Port:")
  imgui.InputInt("###host_port", M.port)

  local mods = FS:findFiles("/mods/", "*.zip", 1000)
  imgui.Text("Mods:")
  imgui.BeginChild1("###Mods", imgui.ImVec2(0, -30), true)
  for k, v in pairs(mods) do
    local enabled = imgui.BoolPtr(M.mods[v] ~= nil)
    if imgui.Checkbox(v.."###host_mod", enabled) then
      if enabled then
        M.mods[v] = v
      else
        M.mods[v] = nil
      end
    end
  end
  imgui.EndChild()
  if imgui.Button("Create") then
    host_server()
  end
end

M.draw = draw

return M
