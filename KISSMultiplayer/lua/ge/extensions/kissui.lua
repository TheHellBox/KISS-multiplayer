local M = {}
M.dependencies = {"ui_imgui"}
M.chat = {
  "KissMP chat"
}

local gui_module = require("ge/extensions/editor/api/gui")
local gui = {setupEditorGuiTheme = nop}
local imgui = ui_imgui
local addr = imgui.ArrayChar(128)
local player_name = imgui.ArrayChar(128)
local message_buffer = imgui.ArrayChar(128)

local function open_ui()
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
    imgui.InputText("Player name", player_name)
    imgui.Spacing()
    imgui.InputText("", addr)
    imgui.SameLine()
    if imgui.Button("Connect") then
      local addr = ffi.string(addr)
      local player_name = ffi.string(player_name)
      network.connect(addr, player_name)
    end
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
