-- Chat Messages Management
local M = {}

--- @class color
--- @param r number Red
--- @param g number Green
--- @param b number Blue 

--- Color constants.
local COLORS = {
  YELLOW = {r = 1, g = 1, b = 0}, ---@type color
  RED = {r = 1, g = 0, b = 0} ---@type color
}

--- @class chat_message
--- @field text string Message text
--- @field color color Text color
--- @field user_color color Username color

--- Contains chat messages.
local chat_messages = {
  {text = "KissMP chat", user_color = nil}
}

-- FIXME: Use hooks so this doesn't have to be done
M.unread_message_count = 0

-- FIXME: USE HOOKS AAAAAAAA
--- Adds a message to the chat table.
--- @param message string
--- @param color color
--- @param sent_by string
local function message_recieved(message, color, sent_by)
  -- TODO: Remove this once hooks are set up.
  M.unread_message_count = M.unread_message_count + 1
  local user_color
  local user_name
  if sent_by ~= nil then
    if network.players[sent_by] then
      local r,g,b,a = kissplayers.get_player_color(sent_by)
      user_color = {r,g,b,a}
      user_name = network.players[sent_by].name
    end
  end

  local message_table = {
    text = message,
    user_color = user_color,
    color = color,
    user_name = user_name
  }
  table.insert(chat_messages, message_table)
end

--- Send a chat message
--- @param message string
local function send_message(message)
  local message_trimmed = message:gsub("^%s*(.-)%s*$", "%1")
  if message_trimmed:len() == 0 then return end
  
  network.send_data(
    {
      Chat = message_trimmed
    },
    true
  )
end

M.message_recieved = message_recieved
M.send_message = send_message
M.chat_messages = chat_messages
M.COLORS = COLORS

return M