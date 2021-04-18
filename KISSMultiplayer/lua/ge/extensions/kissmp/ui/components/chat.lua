local gui = require("kissmp.ui.gui")
local imgui = gui.imgui
local utils = require("kissmp.utils")
local chat = require("kissmp.chat")

local message_buffer = imgui.ArrayChar(128)
local set_column_offset = false
local prev_chat_scroll_max = 0

local function send_current_chat_message()
  local message = ffi.string(message_buffer)
  chat.send_message(message)
  message_buffer = imgui.ArrayChar(128)
end

local function draw_player_list()
  imgui.BeginGroup();
  imgui.Text("Player list:")
  imgui.BeginChild1("PlayerList", imgui.ImVec2(0, 0), true)
  if network.connection.connected then
    for _, player in utils.spairs(network.players, function(t,a,b) return t[b].name:lower() > t[a].name:lower() end) do
      imgui.Text(player.name.."("..player.ping.." ms)")
    end
  end
  imgui.EndChild()
  imgui.EndGroup()
end

local function draw_chat()
  imgui.BeginChild1("ChatWindowUpperContent", imgui.ImVec2(0, -30), true)
  local upper_content_width = imgui.GetWindowContentRegionWidth()
  imgui.Columns(2, "###chat_columns")
  
  if not set_column_offset then
    -- Imgui doesn't have a "first time" method for this, so we track it ourselves..
    imgui.SetColumnOffset(1, upper_content_width - 175)
    set_column_offset = true

  end
  
  -- Draw messages
  imgui.BeginChild1("Scrolling", imgui.ImVec2(0, 0), false)

  for _, message in pairs(chat.chat_messages) do
    imgui.PushTextWrapPos(0)
    if message.user_name ~= nil then
      local color = imgui.ImVec4(message.user_color[1], message.user_color[2], message.user_color[3], message.user_color[4])
      imgui.TextColored(color, "%s", (message.user_name:sub(1, 16))..":")
      imgui.SameLine()
    end
    if message.user_color then
      imgui.TextColored(imgui.ImVec4(message.color.r or 1, message.color.g or 1, message.color.b or 1, message.color.a or 1), "%s", message.text)
    else
      imgui.Text("%s", message.text)
    end
    imgui.PopTextWrapPos()
  end
  
  -- Scroll to bottom and clear unreads
  local scroll_to_bottom = imgui.GetScrollY() >= prev_chat_scroll_max
  if scroll_to_bottom then
    imgui.SetScrollY(imgui.GetScrollMaxY())
    chat.unread_message_count = 0
  end
  prev_chat_scroll_max = imgui.GetScrollMaxY()
  imgui.EndChild()

  -- Draw player list
  imgui.NextColumn()
  draw_player_list()
 
  -- End UpperContent
  imgui.EndChild()
 
  -- Draw chat textbox
  local content_width = imgui.GetWindowContentRegionWidth()
  local button_width = 75
  local textbox_width = content_width - (button_width * 1.075)
  
  imgui.Spacing()
  
  imgui.PushItemWidth(textbox_width)
  if imgui.InputText("##chat", message_buffer, 128, imgui.InputTextFlags_EnterReturnsTrue) then
    send_current_chat_message()
    imgui.SetKeyboardFocusHere(-1)
  end
  imgui.PopItemWidth()
  imgui.SameLine()
  if imgui.Button("Send", imgui.ImVec2(button_width, -1)) then
    send_current_chat_message()
  end
  imgui.PopItemWidth()
end

-- Chat Component
local M = {}

local function onExtensionLoaded()
end

local function onUpdate(dt)
  draw_chat()
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.on_message = on_message

return M