local M = {}

M.VERSION_STR = "0.4.5"

M.downloads = {}
M.downloading = false
M.downloads_status = {}

local current_download = nil

local socket = require("socket")
local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")
local ping_send_time = 0

M.players = {}
M.socket = socket
M.base_secret = "None"
M.connection = {
    tcp = nil,
    connected = false,
    client_id = 0,
    heartbeat_time = 1,
    timer = 0,
    tickrate = 33,
    mods_left = 0,
    ping = 0,
    time_offset = 0
}

local FILE_TRANSFER_CHUNK_SIZE = 16384;

local message_handlers = {}

local time_offset_smoother = {samples = {}, current_sample = 1}

time_offset_smoother.get = function(new_sample)
    if time_offset_smoother.current_sample < 30 then
        time_offset_smoother.samples[time_offset_smoother.current_sample] =
            new_sample
    else
        time_offset_smoother.current_sample = 0
    end
    time_offset_smoother.current_sample =
        time_offset_smoother.current_sample + 1
    local sum = 0
    local n = 0
    for _, v in pairs(time_offset_smoother.samples) do
        sum = sum + v
        n = n + 1
    end
    return sum / n
end

local function disconnect(data)
    local text = "Disconnected!"
    if data then text = text .. " Reason: " .. data end
    kissui.chat.add_message(text)
    M.connection.connected = false
    M.connection.tcp:close()
    M.players = {}
    kissplayers.players = {}
    kissplayers.player_transforms = {}
    kissplayers.players_in_cars = {}
    kissplayers.player_heads_attachments = {}
    kissrichpresence.update()
    returnToMainMenu()
end

local function handle_player_info(player_info)
    M.players[player_info.id] = player_info
end

local function check_lua(l)
    local filters = {
        "FS", "check_lua", "handle_lua", "handle_vehicle_lua", "network =",
        "network=", "message_handlers", "io%.write", "io%.open", "io%.close",
        "fileOpen", "fileExists", "removeDirectory", "removeFile", "io%."
    }

    for _, filter in pairs(filters) do
        if string.find(l, filter) ~= nil then
            kissui.chat.add_message(
                "Possibly malicious lua command has been send, rejecting. Found: " ..
                    filter)
            return false
        end
    end
    return true
end

local function handle_lua(data)
    if check_lua(data) then Lua:queueLuaCommand(data) end
end

local function handle_vehicle_lua(data)
    if not check_lua(data[2]) then return end
    local lua = data[2]
    local id = vehiclemanager.id_map[data[1] or -1] or 0
    local vehicle = be:getObjectByID(id)
    if vehicle then vehicle:queueLuaCommand(lua) end
end

local function handle_pong(data)
    local server_time = data
    local local_time = socket.gettime()
    local ping = local_time - ping_send_time
    if ping > 1 then return end
    local time_diff = server_time - local_time + (ping / 2)
    M.connection.time_offset = time_offset_smoother.get(time_diff)
    M.connection.ping = ping * 1000
end

local function handle_player_disconnected(data)
    local id = data
    M.players[id] = nil
end

local function handle_chat(data) kissui.chat.add_message(data[1], nil, data[2]) end

local function onExtensionLoaded()
    message_handlers.VehicleUpdate = vehiclemanager.update_vehicle
    message_handlers.VehicleSpawn = vehiclemanager.spawn_vehicle
    message_handlers.RemoveVehicle = vehiclemanager.remove_vehicle
    message_handlers.ResetVehicle = vehiclemanager.reset_vehicle
    message_handlers.Chat = handle_chat
    message_handlers.SendLua = handle_lua
    message_handlers.PlayerInfoUpdate = handle_player_info
    message_handlers.VehicleMetaUpdate = vehiclemanager.update_vehicle_meta
    message_handlers.Pong = handle_pong
    message_handlers.PlayerDisconnected = handle_player_disconnected
    message_handlers.VehicleLuaCommand = handle_vehicle_lua
    message_handlers.CouplerAttached = vehiclemanager.attach_coupler
    message_handlers.CouplerDetached = vehiclemanager.detach_coupler
    message_handlers.ElectricsUndefinedUpdate =
        vehiclemanager.electrics_diff_update
end

local function send_data(raw_data, reliable)
    if type(raw_data) == "number" then
        print("NOT IMPLEMENTED. PLEASE REPORT TO KISSMP DEVELOPERS. CODE: " ..
                  raw_data)
        return
    end
    local data = ""
    -- Used in context of it being called from vehicle lua, where it's already encoded into json
    if type(raw_data) == "string" then
        data = raw_data
    else
        data = jsonEncode(raw_data)
    end
    if not M.connection.connected then return -1 end
    local len = #data
    local len = ffi.string(ffi.new("uint32_t[?]", 1, {len}), 4)
    if reliable then
        reliable = 1
    else
        reliable = 0
    end
    M.connection.tcp:send(string.char(reliable) .. len)
    M.connection.tcp:send(data)
end

local function sanitize_addr(addr)
    -- Trim leading and trailing spaces that might occur during a copy/paste
    local sanitized = addr:gsub("^%s*(.-)%s*$", "%1")

    -- Check if port is missing, add default port if so
    if not sanitized:find(":") then sanitized = sanitized .. ":3698" end
    return sanitized
end

local function generate_secret(server_identifier)
    local secret = server_identifier .. M.base_secret
    return hashStringSHA1(secret)
end

local function change_map(map)
    if FS:fileExists(map) or FS:directoryExists(map) then
        vehiclemanager.loading_map = true
        freeroam_freeroam.startFreeroam(map)
    else
        kissui.chat.add_message(
            "Map file doesn't exist. Check if mod containing map is enabled",
            kissui.COLOR_RED)
        disconnect()
    end
end

local function connect(addr, player_name)
    if M.connection.connected then disconnect() end
    M.players = {}

    print("Connecting...")
    addr = sanitize_addr(addr)
    kissui.chat.add_message("Connecting to " .. addr .. "...")
    M.connection.tcp = socket.tcp()
    M.connection.tcp:settimeout(3.0)
    local connected, err = M.connection.tcp:connect("127.0.0.1", "7894")

    -- Send server address to the bridge
    local addr_lenght = ffi.string(ffi.new("uint32_t[?]", 1, {#addr}), 4)
    M.connection.tcp:send(addr_lenght)
    M.connection.tcp:send(addr)

    local connection_confirmed = M.connection.tcp:receive(1)
    if connection_confirmed then
        if connection_confirmed ~= string.char(1) then
            kissui.chat.add_message("Connection failed.", kissui.COLOR_RED)
            return
        end
    else
        kissui.chat.add_message(
            "Failed to confirm connection. Check if bridge is running.",
            kissui.COLOR_RED)
        return
    end

    -- Ignore message type
    M.connection.tcp:receive(1)

    local len, _, _ = M.connection.tcp:receive(4)
    local len = ffi.cast("uint32_t*", ffi.new("char[?]", #len + 1, len))
    local len = len[0]

    local received, _, _ = M.connection.tcp:receive(len)
    print(received)
    local server_info = jsonDecode(received).ServerInfo
    if not server_info then
        print("Failed to fetch server info")
        return
    end
    print("Server name: " .. server_info.name)
    print("Player count: " .. server_info.player_count)

    M.connection.tcp:settimeout(0.0)
    M.connection.connected = true
    M.connection.client_id = server_info.client_id
    M.connection.server_info = server_info
    M.connection.tickrate = server_info.tickrate

    local client_info = {
        ClientInfo = {
            name = player_name,
            secret = generate_secret(server_info.server_identifier),
            client_version = {0, 4}
        }
    }
    send_data(client_info, true)

    kissmods.set_mods_list(server_info.mods)
    kissmods.update_status_all()

    local missing_mods = {}
    local mod_names = {}
    for _, mod in pairs(kissmods.mods) do
        table.insert(mod_names, mod.name)
        if mod.status ~= "ok" then
            table.insert(missing_mods, mod.name)
            M.downloads_status[mod.name] = {name = mod.name, progress = 0}
        end
    end
    M.connection.mods_left = #missing_mods

    kissmods.deactivate_all_mods()
    for k, v in pairs(missing_mods) do print(k .. " " .. v) end
    if #missing_mods > 0 then
        -- Request mods
        send_data({RequestMods = missing_mods}, true)
    end
    vehiclemanager.loading_map = true
    if #missing_mods == 0 then
        kissmods.mount_mods(mod_names)
        change_map(server_info.map)
    end
    kissrichpresence.update()
    kissui.chat.add_message("Connected!")
end

local function send_messagepack(data_type, reliable, data)
    local data = data
    if type(data) == "string" then data = jsonDecode(data) end
    data = messagepack.pack(data)
    send_data(data_type, reliable, data)
end

local function on_finished_download()
    vehiclemanager.loading_map = true
    change_map(M.connection.server_info.map)
end

local function send_ping()
    ping_send_time = socket.gettime()
    send_data({Ping = math.floor(M.connection.ping)}, false)
end

local function cancel_download()
    --[[if not current_download then return end
  io.close(current_download.file)
  current_download = nil
    M.downloading = false]] --
    for k, v in pairs(M.downloads) do M.downloads[k]:close() end
end

local function onUpdate(dt)
    if not M.connection.connected then return end
    if M.connection.timer < M.connection.heartbeat_time then
        M.connection.timer = M.connection.timer + dt
    else
        M.connection.timer = 0
        send_ping()
    end

    while true do
        local msg_type = M.connection.tcp:receive(1)
        if not msg_type then break end
        -- print("msg_t"..string.byte(msg_type))
        M.connection.tcp:settimeout(5.0)
        -- JSON data
        if string.byte(msg_type) == 1 then
            local data = M.connection.tcp:receive(4)
            local len = ffi.cast("uint32_t*", ffi.new("char[?]", 5, data))
            local data, _, _ = M.connection.tcp:receive(len[0])
            M.connection.tcp:settimeout(0.0)
            local data_decoded = jsonDecode(data)
            for k, v in pairs(data_decoded) do
                if message_handlers[k] then
                    message_handlers[k](v)
                end
            end
        elseif string.byte(msg_type) == 0 then -- Binary data
            M.downloading = true
            kissui.show_download = true
            local name_b = M.connection.tcp:receive(4)
            local len_n = ffi.cast("uint32_t*", ffi.new("char[?]", 5, name_b))
            local name, _, _ = M.connection.tcp:receive(len_n[0])
            local chunk_n_b = M.connection.tcp:receive(4)
            local chunk_a_b = M.connection.tcp:receive(4)
            local read_size_b = M.connection.tcp:receive(4)
            local chunk_n = ffi.cast("uint32_t*",
                                     ffi.new("char[?]", 5, chunk_n_b))[0]
            local file_length = ffi.cast("uint32_t*",
                                         ffi.new("char[?]", 5, chunk_a_b))[0]
            local read_size = ffi.cast("uint32_t*",
                                       ffi.new("char[?]", 5, read_size_b))[0]
            local file_data, _, _ = M.connection.tcp:receive(read_size)
            M.downloads_status[name] = {name = name, progress = 0}
            M.downloads_status[name].progress = chunk_n *
                                                    FILE_TRANSFER_CHUNK_SIZE /
                                                    file_length
            local file = M.downloads[name]
            if not file then
                M.downloads[name] = kissmods.open_file(name)
            end
            M.downloads[name]:write(file_data)
            if read_size < FILE_TRANSFER_CHUNK_SIZE then
                M.downloading = false
                kissui.show_download = false
                kissmods.mount_mod(name)
                M.downloads[name]:close()
                M.downloads[name] = nil
                M.downloads_status = {}
                M.connection.mods_left = M.connection.mods_left - 1
            end
            if M.connection.mods_left <= 0 then
                on_finished_download()
            end
            M.connection.tcp:settimeout(0.0)
            break
        elseif string.byte(msg_type) == 2 then
            local len_b = M.connection.tcp:receive(4)
            local len = ffi.cast("uint32_t*", ffi.new("char[?]", 5, len_b))[0]
            local reason, _, _ = M.connection.tcp:receive(len)
            disconnect(reason)
        end
    end
end

local function get_client_id() return M.connection.client_id end

M.get_client_id = get_client_id
M.connect = connect
M.disconnect = disconnect
M.cancel_download = cancel_download
M.send_data = send_data
M.onUpdate = onUpdate
M.send_messagepack = send_messagepack
M.onExtensionLoaded = onExtensionLoaded

return M
