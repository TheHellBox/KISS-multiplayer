local M = {}

M.VERSION_STR = "latest"
M.is_server_public = false

M.downloads = {}
M.downloads_meta = {}
M.downloading = false
M.downloads_status = {}

local current_download = nil
local on_finished_download

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

local FILE_TRANSFER_CHUNK_SIZE = 65536;
local CHUNK_SIZE = 65000  -- Safe size under 65536 limit
local MAX_BINARY_CHUNKS_PER_UPDATE = 48
local MAX_BINARY_BYTES_PER_UPDATE = 2 * 1024 * 1024
local BINARY_FRAME_TIME_BUDGET_MIN = 0.002
local BINARY_FRAME_TIME_BUDGET_MAX = 0.006
local BINARY_FRAME_TIME_BUDGET_RATIO = 0.25
local DOWNLOAD_SPEED_SAMPLE_MIN = 0.2

local message_handlers = {}

local time_offset_smoother = {
    samples = {},
    current_sample = 1,
}

time_offset_smoother.get = function(new_sample)
    if time_offset_smoother.current_sample < 30 then
        time_offset_smoother.samples[time_offset_smoother.current_sample] = new_sample
    else
        time_offset_smoother.current_sample = 0
    end
    time_offset_smoother.current_sample = time_offset_smoother.current_sample + 1
    local sum = 0
    local n = 0
    for _, v in pairs(time_offset_smoother.samples) do
        sum = sum + v
        n = n + 1
    end
    return sum / n
end

local function bytesToU32(str)
    local b1, b2, b3, b4 = str:byte(1, 4)
    return bit.bor(
            bit.lshift(b4, 24),
            bit.lshift(b3, 16),
            bit.lshift(b2, 8),
            b1
    )
end

local function disconnect(data)
    local text = "Disconnected!"
    if data then
        text = text .. " Reason: " .. data
    end
    kissui.chat.add_message(text)
    M.connection.connected = false
    M.connection.tcp:close()
    M.players = {}
    kissplayers.players = {}
    kissplayers.player_transforms = {}
    kissplayers.players_in_cars = {}
    kissplayers.player_heads_attachments = {}
    kissrichpresence.update()
    --vehiclemanager.id_map = {}
    --vehiclemanager.ownership = {}
    --vehiclemanager.delay_spawns = false
    --kissui.force_disable_nametags = false
    --Lua:requestReload()
    --kissutils.hooks.clear()
    returnToMainMenu()
end

local function handle_disconnected(data)
    disconnect(data)
end

local function handle_file_transfer(data)
    kissui.show_download = true
    -- local file_len = ffi.cast("uint32_t*", ffi.new("char[?]", 5, data:sub(1, 4)))[0]
    local file_len = bytesToU32(data:sub(1, 4))
    local file_name = data:sub(5, #data)
    local chunks = math.floor(file_len / FILE_TRANSFER_CHUNK_SIZE)

    current_download = {
        file_len = file_len,
        file_name = file_name,
        chunks = chunks,
        last_chunk = file_len - chunks * FILE_TRANSFER_CHUNK_SIZE,
        current_chunk = 0,
        file = kissmods.open_file(file_name)
    }
    M.downloading = true
end

local function handle_player_info(player_info)
    M.players[player_info.id] = player_info
end

local function check_lua(l)
    local filters = { "FS", "check_lua", "handle_lua", "handle_vehicle_lua", "network =", "network=", "message_handlers", "io%.write", "io%.open", "io%.close", "fileOpen", "fileExists", "removeDirectory", "removeFile", "io%." }
    for k, v in pairs(filters) do
        if string.find(l, v) ~= nil then
            kissui.chat.add_message("Possibly malicious lua command has been send, rejecting. Found: " .. v)
            return false
        end
    end
    return true
end

local function handle_lua(data)
    if M.is_server_public then
        print("Blocked arbitrary Lua command from public server.")
        return
    end

    if check_lua(data) then
        Lua:queueLuaCommand(data)
    end
end

local function handle_vehicle_lua(data)
    if M.is_server_public then
        print("Blocked arbitrary vehicle Lua command from public server.")
        return
    end

    local id = data[1]
    local lua = data[2]
    local id = vehiclemanager.id_map[id or -1] or 0
    local vehicle = be:getObjectByID(id)
    if vehicle and check_lua(lua) then
        vehicle:queueLuaCommand(lua)
    end
end

local function handle_pong(data)
    local server_time = data
    local local_time = socket.gettime()
    local ping = local_time - ping_send_time
    if ping > 1 then
        return
    end
    local time_diff = server_time - local_time + (ping / 2)
    M.connection.time_offset = time_offset_smoother.get(time_diff)
    M.connection.ping = ping * 1000
end

local function handle_player_disconnected(data)
    local id = data
    M.players[id] = nil
end

local function handle_bridge_mod_downloaded(name)
    if not name then
        return
    end

    kissmods.mount_mod(name)
    M.downloads_status[name] = nil
    M.connection.mods_left = M.connection.mods_left - 1

    if M.connection.mods_left <= 0 then
        M.downloading = false
        kissui.show_download = false
        on_finished_download()
    end
end

local function update_download_speed(status, received_bytes)
    if not status then
        return
    end

    local now = socket.gettime()
    local received = math.max(received_bytes or 0, 0)

    status.received_bytes = received
    status.speed_bps = status.speed_bps or 0

    if not status.last_speed_ts then
        status.last_speed_ts = now
        status.last_speed_bytes = received
        return
    end

    local dt = now - status.last_speed_ts
    if dt <= 0 then
        return
    end

    local delta = received - (status.last_speed_bytes or 0)
    if delta < 0 then
        status.last_speed_ts = now
        status.last_speed_bytes = received
        return
    end

    if dt >= DOWNLOAD_SPEED_SAMPLE_MIN then
        local instant_bps = delta / dt
        status.speed_bps = (status.speed_bps * 0.65) + (instant_bps * 0.35)
        status.last_speed_ts = now
        status.last_speed_bytes = received
    end
end

local function handle_bridge_mod_download_progress(data)
    if not data or not data.name then
        return
    end

    local status = M.downloads_status[data.name]
    if not status then
        status = {
            name = data.name,
            progress = 0,
            received_bytes = 0,
            speed_bps = 0,
        }
        M.downloads_status[data.name] = status
    end

    status.progress = math.min(math.max(data.progress or 0, 0), 1)
    local mod = kissmods.mods[data.name]
    if mod and mod.size then
        update_download_speed(status, mod.size * status.progress)
    end

    M.downloading = true
    kissui.show_download = true
end

local function handle_chat(data)
    kissui.chat.add_message(data[1], nil, data[2])
end

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
    message_handlers.BridgeModDownloaded = handle_bridge_mod_downloaded
    message_handlers.BridgeModDownloadProgress = handle_bridge_mod_download_progress
    message_handlers.VehicleLuaCommand = handle_vehicle_lua
    message_handlers.CouplerAttached = vehiclemanager.attach_coupler
    message_handlers.CouplerDetached = vehiclemanager.detach_coupler
    message_handlers.ElectricsUndefinedUpdate = vehiclemanager.electrics_diff_update

    message_handlers.VehicleSetPosition = vehiclemanager.set_position
    message_handlers.VehicleSetPositionRotation = vehiclemanager.set_position_rotation
    message_handlers.VehicleResetInPlace = vehiclemanager.reset_in_place
end

local function send_data(raw_data, reliable)
    if type(raw_data) == "number" then
        print("NOT IMPLEMENTED. PLEASE REPORT TO KISSMP DEVELOPERS. CODE: " .. raw_data)
        return
    end
    if not M.connection.connected then
        return -1
    end
    local data = ""
    if type(raw_data) == "string" then
        data = raw_data
    else
        data = jsonEncode(raw_data)
    end
    local data_size = #data
    -- Auto-chunk if data is too large
    if data_size > CHUNK_SIZE then
        print("Large data detected: " .. data_size .. " bytes, sending in chunks")
        local num_chunks = math.ceil(data_size / CHUNK_SIZE)

        for i = 0, num_chunks - 1 do
            local start_pos = i * CHUNK_SIZE + 1
            local end_pos = math.min((i + 1) * CHUNK_SIZE, data_size)
            local chunk = data:sub(start_pos, end_pos)

            local chunk_data = jsonEncode({
                DataChunk = {
                    chunk_index = i,
                    total_chunks = num_chunks,
                    data = chunk
                }
            })

            local len = ffi.string(ffi.new("uint32_t[?]", 1, { #chunk_data }), 4)
            M.connection.tcp:send(string.char(1) .. len)
            M.connection.tcp:send(chunk_data)

            print("Sent chunk " .. (i + 1) .. "/" .. num_chunks)
        end

        print("All chunks sent successfully")
        return 0
    end

    -- Send normally
    local len = ffi.string(ffi.new("uint32_t[?]", 1, { data_size }), 4)
    if reliable then
        reliable = 1
    else
        reliable = 0
    end
    M.connection.tcp:send(string.char(reliable) .. len)
    M.connection.tcp:send(data)
    return 0
end

local function sanitize_addr(addr)
    -- Trim leading and trailing spaces that might occur during a copy/paste
    local sanitized = addr:gsub("^%s*(.-)%s*$", "%1")

    -- Check if port is missing, add default port if so
    if not sanitized:find(":") then
        sanitized = sanitized .. ":3698"
    end
    return sanitized
end

local function generate_secret(server_identifier)
    local secret = server_identifier .. M.base_secret
    return hashStringSHA1(secret)
end

local function get_bridge_mods_dir()
    local base = nil

    if type(getUserPath) == "function" then
        base = getUserPath()
    end

    if (not base or base == "") and FS and type(FS.getUserPath) == "function" then
        base = FS:getUserPath()
    end

    if not base or base == "" then
        return ""
    end

    base = tostring(base)
    base = base:gsub("[/\\]+$", "")
    return base .. "/kissmp_mods"
end

local function change_map(map)
    if FS:fileExists(map) or FS:directoryExists(map) then
        vehiclemanager.loading_map = true
        freeroam_freeroam.startFreeroam(map)
    else
        kissui.chat.add_message("Map file doesn't exist. Check if mod containing map is enabled", kissui.COLOR_RED)
        disconnect()
    end
end

local function connect(addr, player_name, is_public)
    M.is_server_public = is_public or false

    if M.connection.connected then
        disconnect()
    end
    M.players = {}

    print("Connecting...")
    addr = sanitize_addr(addr)
    kissui.chat.add_message("Connecting to " .. addr .. "...")
    M.connection.tcp = socket.tcp()
    M.connection.tcp:settimeout(3.0)
    local connected, err = M.connection.tcp:connect("127.0.0.1", "7894")

    -- Send server address to the bridge
    local addr_lenght = ffi.string(ffi.new("uint32_t[?]", 1, { #addr }), 4)
    M.connection.tcp:send(addr_lenght)
    M.connection.tcp:send(addr)

    -- Provide bridge with the real mods directory from the current Lua environment.
    local mods_dir = get_bridge_mods_dir()
    local mods_dir_length = ffi.string(ffi.new("uint32_t[?]", 1, { #mods_dir }), 4)
    M.connection.tcp:send(mods_dir_length)
    if #mods_dir > 0 then
        M.connection.tcp:send(mods_dir)
    end

    local connection_confirmed = M.connection.tcp:receive(1)
    if connection_confirmed then
        if connection_confirmed ~= string.char(1) then
            kissui.chat.add_message("Connection failed.", kissui.COLOR_RED)
            return
        end
    else
        kissui.chat.add_message("Failed to confirm connection. Check if bridge is running.", kissui.COLOR_RED)
        return
    end

    -- Ignore message type
    M.connection.tcp:receive(1)

    local len, _, _ = M.connection.tcp:receive(4)
    len = bytesToU32(len)

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

    local steamid64 = nil
    if Steam and Steam.isWorking then
        steamid64 = Steam.accountID ~= "0" and Steam.accountID or nil
    end

    local client_info = {
        ClientInfo = {
            name = player_name,
            secret = generate_secret(server_info.server_identifier),
            steamid64 = steamid64,
            client_version = { 0, 8 }
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
            print(string.format(
                    "[KISSMP][MOD-CHECK] request=%s status=%s reason=%s server_hash=%s local_hash=%s size=%s",
                    tostring(mod.name),
                    tostring(mod.status),
                    tostring(mod.debug_reason or "unknown"),
                    tostring(mod.hash or ""),
                    tostring(mod.local_hash or ""),
                    tostring(mod.size or 0)
            ))
            table.insert(missing_mods, mod.name)
            M.downloads_status[mod.name] = { name = mod.name, progress = 0, received_bytes = 0, speed_bps = 0 }
        else
            print(string.format(
                    "[KISSMP][MOD-CHECK] keep=%s status=ok reason=%s hash=%s",
                    tostring(mod.name),
                    tostring(mod.debug_reason or "ok"),
                    tostring(mod.hash or "")
            ))
        end
    end
    M.connection.mods_left = #missing_mods

    kissmods.deactivate_all_mods()
    for k, v in pairs(missing_mods) do
        print(k .. " " .. v)
    end
    if #missing_mods > 0 then
        -- Do not allow public servers to force mod downloads
        if M.is_server_public then
            kissui.chat.add_message("Cannot auto-download mods from public servers")
            disconnect()
            return
        else
            M.downloading = true
            kissui.show_download = true
            -- Request mods when using direct IP
            send_data(
                    {
                        RequestMods = missing_mods
                    },
                    true
            )
        end
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
    if type(data) == "string" then
        data = jsonDecode(data)
    end
    data = messagepack.pack(data)
    send_data(data_type, reliable, data)
end

on_finished_download = function()
    vehiclemanager.loading_map = true
    change_map(M.connection.server_info.map)
end

local function send_ping()
    ping_send_time = socket.gettime()
    send_data(
            {
                Ping = math.floor(M.connection.ping),
            },
            false
    )
end

local function cancel_download()
    --[[if not current_download then return end
    io.close(current_download.file)
    current_download = nil
      M.downloading = false]]--
    for k, v in pairs(M.downloads) do
        M.downloads[k]:close()
    end
  M.downloads = {}
  M.downloads_meta = {}
  M.downloads_status = {}
end

local function onUpdate(dt)
    if not M.connection.connected then
        return
    end
    if M.connection.timer < M.connection.heartbeat_time then
        M.connection.timer = M.connection.timer + dt
    else
        M.connection.timer = 0
        send_ping()
    end

  local update_start = socket.gettime()
  local frame_time_budget = math.max(BINARY_FRAME_TIME_BUDGET_MIN, dt * BINARY_FRAME_TIME_BUDGET_RATIO)
  frame_time_budget = math.min(frame_time_budget, BINARY_FRAME_TIME_BUDGET_MAX)
  local binary_chunks_processed = 0
  local binary_bytes_processed = 0
    while true do
    if binary_chunks_processed > 0 then
      if binary_chunks_processed >= MAX_BINARY_CHUNKS_PER_UPDATE then break end
      if binary_bytes_processed >= MAX_BINARY_BYTES_PER_UPDATE then break end
      if (socket.gettime() - update_start) >= frame_time_budget then break end
    end

        local msg_type = M.connection.tcp:receive(1)
        if not msg_type then
            break
        end
        --print("msg_t"..string.byte(msg_type))
        M.connection.tcp:settimeout(5.0)
        -- JSON data
        if string.byte(msg_type) == 1 then
            local data = M.connection.tcp:receive(4)
            local len = bytesToU32(data)
            local data, _, _ = M.connection.tcp:receive(len)
            M.connection.tcp:settimeout(0.0)
            local data_decoded = jsonDecode(data)
            for k, v in pairs(data_decoded) do
                if message_handlers[k] then
                    message_handlers[k](v)
                end
            end
        elseif string.byte(msg_type) == 0 then
            -- Binary data
            M.downloading = true
            kissui.show_download = true
            local name_b = M.connection.tcp:receive(4)
            local len_n = bytesToU32(name_b)
            local name, _, _ = M.connection.tcp:receive(len_n)
            local chunk_n_b = M.connection.tcp:receive(4)
            local chunk_a_b = M.connection.tcp:receive(4)
            local read_size_b = M.connection.tcp:receive(4)
            local chunk_n = bytesToU32(chunk_n_b)
            local chunk_a = bytesToU32(chunk_a_b)
            local read_size = bytesToU32(read_size_b)
            local file_length = chunk_a
            local file_data, _, _ = M.connection.tcp:receive(read_size)

      local meta = M.downloads_meta[name]
      if not meta then
        meta = {
          file_length = file_length,
          received = 0,
        }
        M.downloads_meta[name] = meta
      end

      local status = M.downloads_status[name]
      if not status then
        status = {
          name = name,
          progress = 0,
          received_bytes = 0,
          speed_bps = 0,
        }
        M.downloads_status[name] = status
      end

            local file = M.downloads[name]
            if not file then
                M.downloads[name] = kissmods.open_file(name)
            end
            M.downloads[name]:write(file_data)
      meta.received = meta.received + read_size
      status.progress = math.min(meta.received / math.max(file_length, 1), 1)
      update_download_speed(status, meta.received)

      binary_chunks_processed = binary_chunks_processed + 1
      binary_bytes_processed = binary_bytes_processed + read_size

      if meta.received >= file_length then
                M.downloading = false
                kissui.show_download = false
                kissmods.mount_mod(name)
                M.downloads[name]:close()
                M.downloads[name] = nil
        M.downloads_meta[name] = nil
        M.downloads_status[name] = nil
                M.connection.mods_left = M.connection.mods_left - 1
        if M.connection.mods_left == 0 then
          on_finished_download()
        end
            end
            M.connection.tcp:settimeout(0.0)
        elseif string.byte(msg_type) == 2 then
            local len_b = M.connection.tcp:receive(4)
            local len = bytesToU32(len_b)
            local reason, _, _ = M.connection.tcp:receive(len)
            disconnect(reason)
        end
    end
end

local function get_client_id()
    return M.connection.client_id
end

local function onLoadingScreenFadeout()
  if M.connection.connected then
    core_gamestate.setGameState('kissmp', 'freeroam', 'freeroam')
  end
end

M.onLoadingScreenFadeout = onLoadingScreenFadeout

M.get_client_id = get_client_id
M.connect = connect
M.disconnect = disconnect
M.cancel_download = cancel_download
M.send_data = send_data
M.onUpdate = onUpdate
M.send_messagepack = send_messagepack
M.onExtensionLoaded = onExtensionLoaded

return M
