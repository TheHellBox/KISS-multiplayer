local M = {}
local http = require("socket.http")

M.dependencies = {"ui_imgui"}
M.chat = {
  "KissMP chat"
}
M.server_list = {}
M.master_addr = "http://185.87.49.206:3692/"
M.bridge_launched = false

M.show_download = false
M.download_progress = 0

local gui_module = require("ge/extensions/editor/api/gui")
local gui = {setupEditorGuiTheme = nop}
local imgui = ui_imgui
local addr = imgui.ArrayChar(128)
local player_name = imgui.ArrayChar(128)
local message_buffer = imgui.ArrayChar(128)

local function refresh_server_list()
  local b, _, _  = http.request("http://127.0.0.1:3693/check")
  if b and b == "ok" then
    M.bridge_launched = true
  end
  local b, _, _  = http.request("http://127.0.0.1:3693/"..M.master_addr)
  if b then
    M.server_list = jsonDecode(b) or {}
  end
end

local function open_ui()
  refresh_server_list()
  gui_module.initialize(gui)
  gui.registerWindow("KissMP", imgui.ImVec2(256, 256))
  gui.showWindow("KissMP")
  gui.registerWindow("Chat", imgui.ImVec2(256, 256))
  gui.showWindow("Chat")
  gui.registerWindow("Download", imgui.ImVec2(256, 128))
  gui.showWindow("Download")
end

local function draw_menu()
  if not gui.isWindowVisible("KissMP") then return end
  gui.setupWindow("KissMP")
  if imgui.Begin("KissMP", gui.getWindowVisibleBoolPtr("KissMP")) then
    imgui.Text("Player name:")
    imgui.InputText("##name", player_name)
    imgui.Text("Server address:")
    imgui.InputText("##addr", addr)
    imgui.SameLine()
    if imgui.Button("Connect") then
      local addr = ffi.string(addr)
      local player_name = ffi.string(player_name)
      network.connect(addr, player_name)
    end
    imgui.Text("Server list:")
    if imgui.Button("Refresh list") then
      refresh_server_list()
    end
    imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)

    local server_count = 0
    for addr, server in pairs(M.server_list) do
      server_count = server_count + 1
      if imgui.CollapsingHeader1(server.name.." ["..server.player_count.."/"..server.max_players.."]") then
        imgui.PushTextWrapPos(0)
        imgui.Text("Address: "..addr)
        imgui.Text("Map: "..server.map)
        imgui.Text(server.description)
        imgui.PopTextWrapPos()
        if imgui.Button("Connect") then
          local player_name = ffi.string(player_name)
          network.connect(addr, player_name)
        end
      end
    end

    imgui.PushTextWrapPos(0)
    if not M.bridge_launched then
      imgui.Text("Bridge is not launched. Please, launch the bridge and then hit 'Refresh list' button")
    elseif server_count == 0 then
      imgui.Text("Server list is empty")
    end
    imgui.PopTextWrapPos()

    imgui.EndChild()
  end
  imgui.End()
end

local function draw_chat()
  if not gui.isWindowVisible("Chat") then return end
  if imgui.Begin("Chat", gui.getWindowVisibleBoolPtr("Chat")) then
    imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)

    for _, message in pairs(M.chat) do
      imgui.PushTextWrapPos(0)
      imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), message)
      imgui.PopTextWrapPos()
    end
    imgui.EndChild()
    imgui.Spacing()
    if imgui.InputText("##chat", message_buffer, 128, imgui.InputTextFlags_EnterReturnsTrue) then
      local message = ffi.string(message_buffer)
      network.send_data(8, true, message)
      imgui.SetKeyboardFocusHere(-1)
      message_buffer = imgui.ArrayChar(128)
    end
    imgui.SameLine()
    if imgui.Button("Send") then
      local message = ffi.string(message_buffer)
      network.send_data(8, true, message)
      message_buffer = imgui.ArrayChar(128)
    end
  end
  imgui.End()
end

local function draw_download()
  if not M.show_download then return end
  if not gui.isWindowVisible("Download") then return end
  if imgui.Begin("Download", gui.getWindowVisibleBoolPtr("Download")) then
    --local draw_list = imgui.GetOverlayDrawList1()
    --imgui.ImDrawList_AddRectFilled(draw_list, imgui.ImVec2(30, 30), imgui.ImVec2(30 + M.download_progress * 200, 60), imgui.Col_ButtonHovered)
    imgui.Text("Downloading "..network.download_info.file_name.."...")
    imgui.Text("Progress: "..math.floor(M.download_progress * 100).."/100")
  end
  imgui.End()
end

local function draw_names()
  for id, player in pairs(network.players) do
    local vehicle = vehiclemanager.id_map[player.current_vehicle] or 0
    local vehicle = be:getObjectByID(vehicle)
    if vehicle and (id == network.connection.client_id) then
      local vehicle_position = vehicle:getPosition()
      local local_position = be:getPlayerVehicle(0):getPosition()
      local distance = vec3(vehicle_position):distance(vec3(local_position))
      vehicle_position.z = vehicle_position.z + 1.6
      debugDrawer:drawTextAdvanced(
        vehicle_position,
        String(player.name.." ("..tostring(math.floor(distance)).."m)"),
        ColorF(1, 1, 1, 1),
        true,
        false,
        ColorI(0, 0, 0, 255)
      )
    end
  end
end

local function onUpdate()
  draw_menu()
  draw_chat()
  draw_download()
  draw_names()
end

local function add_message(message)
  table.insert(M.chat, message)
end

M.onExtensionLoaded = open_ui
M.onUpdate = onUpdate
M.add_message = add_message
M.draw_download = draw_download

return M
