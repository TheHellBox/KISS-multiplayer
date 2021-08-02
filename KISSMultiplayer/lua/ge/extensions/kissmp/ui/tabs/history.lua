local M = {}
local imgui = ui_imgui

local history_servers = {}

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

local function save_history()
    local file = io.open("./settings/kissmp_history.json", "w")
    file:write(jsonEncode(history_servers))
    io.close(file)
end

local function load_history(m)
    local kissui = kissui or m
    local file = io.open("./settings/kissmp_history.json", "r")
    if file then
        local content = file:read("*a")
        history_servers = jsonDecode(content) or {}
        io.close(file)
    end
end

local function add_server(addr, server)
    history_servers[addr] = server
    save_history()
end

local function draw_server_description(description)
    local min_height = 64
    local rect_color = imgui.GetColorU322(imgui.ImVec4(0.15, 0.15, 0.15, 1))

    local bg_size = imgui.CalcTextSize(description, nil, false,
                                       imgui.GetWindowContentRegionWidth())
    bg_size.y = math.max(min_height, bg_size.y)
    bg_size.x = imgui.GetWindowContentRegionWidth()

    local cursor_pos_before = imgui.GetCursorPos()
    imgui.Dummy(bg_size)
    local r_min = imgui.GetItemRectMin()
    local r_max = imgui.GetItemRectMax()
    local cursor_pos_after = imgui.GetCursorPos()

    imgui.ImDrawList_AddRectFilled(imgui.GetWindowDrawList(), r_min, r_max,
                                   rect_color)

    imgui.SetCursorPos(cursor_pos_before)
    imgui.Text(description)
    imgui.SetCursorPos(cursor_pos_after)
    imgui.Spacing(2)
end

local function draw()
    local history_count = 0

    imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)
    for addr, server in spairs(history_servers, function(t, a, b)
        return t[b].name:lower() > t[a].name:lower()
    end) do
        local server_from_list = kissui.tabs.server_list.server_list[addr]
        local server_found_in_list = server_from_list ~= nil
        history_count = history_count + 1

        local header = server.name
        if server.added_manually then
            header = header .. " [USER]"
        elseif server_found_in_list then
            header = header .. " [" .. server_from_list.player_count .. "/" ..
                         server_from_list.max_players .. "]"
        else
            header = header .. " [OFFLINE]"
        end
        header = header .. "###server_header_" .. tostring(history_count)

        if imgui.CollapsingHeader1(header) then
            imgui.PushTextWrapPos(0)
            imgui.Text("Address: " .. addr)

            if server_found_in_list then
                imgui.Text("Map: " .. server_from_list.map)
            end

            if server.description and server.description:len() > 0 then
                draw_server_description(server.description)
            end

            imgui.PopTextWrapPos()
            if imgui.Button("Connect###connect_button_" ..
                                tostring(history_count)) then
                kissconfig.save_config()
                local player_name = ffi.string(kissui.player_name)
                network.connect(addr, player_name)
            end
        end
    end

    imgui.PushTextWrapPos(0)
    if history_count == 0 then imgui.Text("No server history found") end
    imgui.PopTextWrapPos()

    imgui.EndChild()

    local content_width = imgui.GetWindowContentRegionWidth()
    local button_width = content_width * 0.495

    if imgui.Button("Refresh List", imgui.ImVec2(button_width, 0)) then
        kissui.tabs.server_list.refresh()
        kissui.tabs.server_list.update_filtered()
    end
    imgui.SameLine()
    if imgui.Button("Clear History", imgui.ImVec2(button_width, 0)) then
        for addr, _ in pairs(history_servers) do
            history_servers[addr] = nil
        end
        save_history()
    end
end

load_history()

M.add_server = add_server
M.draw = draw
M.load = load_history

return M
