local M = {}
local imgui = ui_imgui

local set_column_offset = false
local should_draw_unread_count = false
local unread_message_count = 0
local prev_chat_scroll_max = 0
local message_buffer = imgui.ArrayChar(128)
local history = {}
local historyPos = -1
local docked = false

local inputCallbackC = ffi.cast("ImGuiInputTextCallback", function(data)
    if data.EventFlag == imgui.InputTextFlags_CallbackHistory then
        local prevHistoryPos = historyPos
        if data.EventKey == imgui.Key_UpArrow then
            historyPos = historyPos - 1
            if historyPos < 1 then
                if historyPos < 0 then
                    historyPos = #history
                else
                    historyPos = 1
                end
            end
        elseif data.EventKey == imgui.Key_DownArrow then
            historyPos = historyPos + 1
            if historyPos > #history then historyPos = #history end
            if prevHistoryPos == -1 then historyPos = 1 end
        end

        if #history > 0 and prevHistoryPos ~= historyPos then
            local t = history[historyPos]
            if type(t) ~= "string" then return imgui.Int(0) end
            local inplen = string.len(t)
            local inplenInt = imgui.Int(inplen)
            ffi.copy(data.Buf, t, math.min(data.BufSize - 1, inplen + 1))
            data.CursorPos = inplenInt
            data.SelectionStart = inplenInt
            data.SelectionEnd = inplenInt
            data.BufTextLen = inplenInt
            data.BufDirty = imgui.Bool(true);
        end
    elseif data.EventFlag == imgui.InputTextFlags_CallbackCharFilter and
        data.EventChar == 96 then -- 96 = '`'
        return imgui.Int(1)
    end
    return imgui.Int(0)
end)

M.focus_chat = false
M.chat = {{text = "Chatbox", has_color = false}}

-- Server list update and search
-- spairs from https://stackoverflow.com/a/15706820
local function spairs(t, order)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    if order then
        table.sort(keys, function(a, b) return order(t, a, b) end)
    else
        table.sort(keys)
    end
    local i = 0
    return function()
        i = i + 1
        if keys[i] then return keys[i], t[keys[i]] end
    end
end

local function send_current_chat_message()
    local message = ffi.string(message_buffer)
    local message_trimmed = message:gsub("^%s*(.-)%s*$", "%1")
    if message_trimmed:len() == 0 then return end

    network.send_data({Chat = message_trimmed}, true)
    message_buffer = imgui.ArrayChar(128)
    table.insert(history, message_trimmed)
    historyPos = -1

    for k, v in pairs(history) do print(k .. ' ' .. tostring(v)) end
end

local function draw_player_list()
    imgui.BeginGroup();
    imgui.Text("Current Players")
    if network.connection.connected then
        for _, player in spairs(network.players, function(t, a, b)
            return t[b].name:lower() > t[a].name:lower()
        end) do imgui.Text(player.name .. "(" .. player.ping .. " ms)") end
    end
    imgui.EndGroup()
end

local flags = 0
flags = flags + imgui.InputTextFlags_EnterReturnsTrue
flags = flags + imgui.InputTextFlags_CallbackHistory

local function draw()
    if not kissui.gui.isWindowVisible("Chat") then return end
    imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(100, 100))

    local window_title = "Chat"
    if unread_message_count > 0 and should_draw_unread_count then
        window_title = window_title .. " (" .. tostring(unread_message_count) ..
                           ")"
    end
    window_title = window_title .. "###chat"

    if not docked then imgui.SetNextWindowBgAlpha(kissui.window_opacity[0]) end

    imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
    if imgui.Begin(window_title) then
        docked = imgui.IsWindowDocked()
        local content_width = imgui.GetWindowContentRegionWidth()
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

        for _, message in pairs(M.chat) do
            imgui.PushTextWrapPos(0)
            if message.user_name ~= nil then
                local color = imgui.ImVec4(message.user_color[1],
                                           message.user_color[2],
                                           message.user_color[3],
                                           message.user_color[4])
                imgui.TextColored(color, "%s",
                                  (message.user_name:sub(1, 16)) .. ":")
                imgui.SameLine()
            end
            if message.has_color then
                imgui.TextColored(imgui.ImVec4(message.color.r or 1,
                                               message.color.g or 1,
                                               message.color.b or 1,
                                               message.color.a or 1), "%s",
                                  message.text)
            else
                imgui.Text("%s", message.text)
            end
            imgui.PopTextWrapPos()
        end

        -- Scroll to bottom and clear unreads
        local scroll_to_bottom = imgui.GetScrollY() >= prev_chat_scroll_max
        if scroll_to_bottom then
            imgui.SetScrollY(imgui.GetScrollMaxY())
            unread_message_count = 0
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
        local button_height = 25
        local textbox_width = content_width - (button_width * 2.135)

        imgui.Spacing()

        imgui.PushItemWidth(textbox_width)
        if M.focus_chat then
            imgui.SetKeyboardFocusHere(0)
            M.focus_chat = false
        end
        if imgui.InputText("##chat", message_buffer, 128, flags, inputCallbackC) then
            send_current_chat_message()
            imgui.SetKeyboardFocusHere(-1)
        end
        imgui.SameLine()
        if imgui.Button("Send", imgui.ImVec2(button_width, button_height)) then
            send_current_chat_message()
        end
        imgui.SameLine()
        if imgui.Button("Clear", imgui.ImVec2(button_width, button_height)) then
            for tbl in pairs(M.chat) do
                if M.chat[tbl].text ~= 'Chatbox' then
                    M.chat[tbl] = nil
                end
            end
        end
        imgui.PopItemWidth()
    end
    imgui.End()
    imgui.PopStyleVar(1)
    should_draw_unread_count = true
end

local function add_message(message, color, sent_by)
    unread_message_count = unread_message_count + 1
    should_draw_unread_count = false
    local user_color
    local user_name
    if sent_by ~= nil then
        if network.players[sent_by] then
            local r, g, b, a = kissplayers.get_player_color(sent_by)
            user_color = {r, g, b, a}
            user_name = network.players[sent_by].name
        end
    end
    local has_color = color ~= nil and type(color) == 'table'
    local message_table = {
        text = message,
        has_color = has_color,
        user_color = user_color,
        user_name = user_name
    }
    if has_color then message_table.color = color end

    table.insert(M.chat, message_table)
end

M.draw = draw
M.add_message = add_message

return M
