local M = {}
local http = require("socket.http")

M.dependencies = {"ui_imgui"}
M.chat = {
  "KissMP chat"
}
M.server_list = {}
M.master_addr = "http://185.87.49.206:3692/"
M.bridge_launched = false

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
  gui.registerWindow("KissMP", imgui.ImVec2(128, 128))
  gui.showWindow("KissMP")
  gui.registerWindow("Chat", imgui.ImVec2(128, 128))
  gui.showWindow("Chat")
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
    if imgui.InputText("", message_buffer, 128, imgui.InputTextFlags_EnterReturnsTrue) then
      local message = ffi.string(message_buffer)
      network.send_data(8, true, message)
      imgui.SetKeyboardFocusHere(-1)
      -- idk if that's a correct way to do that
      message_buffer = imgui.ArrayChar(128)
    end
  end
  imgui.End()
end

local function onUpdate()
  draw_menu()
  draw_chat()
end

local function add_message(message)
  table.insert(M.chat, message)
end

M.onExtensionLoaded = open_ui
M.onUpdate = onUpdate
M.add_message = add_message

return M
