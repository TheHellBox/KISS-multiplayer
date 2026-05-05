local M = {}
local imgui = ui_imgui
local http = require("socket.http")
local ffi = require("ffi")

M.servers = {}
local did_initial_refresh = false
local local_ip = nil
local refresh_timer = 0
local REFRESH_INTERVAL = 3

local function safe_decode_json(body)
  if not body or body == "" then return {} end
  local ok, data = pcall(function() return jsonDecode(body) end)
  if ok and type(data) == "table" then return data end
  return {}
end

local function fetch_local_ip()
  local body, code = http.request("http://127.0.0.1:3693/system/ip")
  if code == 200 and body and body ~= "" then
    local_ip = body
  end
end

local function refresh()
  local body, code = http.request("http://127.0.0.1:3693/lan/list")
  if code == 200 and body then
    M.servers = safe_decode_json(body)
  else
    M.servers = {}
  end
end

local function connect_to_server(server)
  if not server or not server.addr then return end
  local player_name = "Player"
  if kissmp_ui and kissmp_ui.player_name then
    player_name = ffi.string(kissmp_ui.player_name)
  end
  kissmp_network.connect(server.addr, player_name, false)
end

local function draw_server_card(server, i)
  local player_count = tonumber(server.player_count) or 0
  local max_players = tonumber(server.max_players) or 0
  local title = string.format("%s [%d/%d]", server.name or "Local Server", player_count, max_players)

  imgui.Text(title)

  imgui.Text("Direccion: " .. tostring(server.addr or "?"))
  imgui.SameLine()
  if imgui.Button("Copiar##copy_" .. tostring(i)) then
    imgui.SetClipboardText(tostring(server.addr))
  end

  imgui.Text("Mapa: " .. tostring(server.map or "?"))

  if server.is_self then
    imgui.TextColored(imgui.ImVec4(0.2, 1, 0.2, 1), "(Hosteado en este PC)")
  end

  if imgui.Button("Conectar##local_" .. tostring(i), imgui.ImVec2(-1, 0)) then
    connect_to_server(server)
  end

  imgui.Separator()
end

local function draw(dt)
  dt = dt or 0
  if not did_initial_refresh then
    refresh()
    fetch_local_ip()
    did_initial_refresh = true
  end

  refresh_timer = refresh_timer + dt
  if refresh_timer >= REFRESH_INTERVAL then
    refresh_timer = 0
    refresh()
  end

  -- IP local del PC para compartir con amigos
  if local_ip then
    imgui.TextColored(imgui.ImVec4(0.8, 0.8, 1, 1), "Tu IP en LAN: " .. local_ip)
    imgui.SameLine()
    if imgui.Button("Copiar IP##copy_self") then
      imgui.SetClipboardText(local_ip)
    end
    imgui.Separator()
  end

  if #M.servers == 0 then
    imgui.TextWrapped("Buscando servidores en la red local... Si hay un servidor activo aparecera aqui en unos segundos.")
  else
    for i, server in ipairs(M.servers) do
      draw_server_card(server, i)
    end
  end

  if imgui.Button("Actualizar##local_refresh", imgui.ImVec2(-1, 0)) then
    refresh()
    fetch_local_ip()
  end
end

M.refresh = refresh
M.draw = draw

return M
