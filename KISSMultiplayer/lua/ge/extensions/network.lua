local M = {}

local version = require("lua/ge/extensions/kissmp/version")
M.VERSION_STR = version.VERSION_STR
M.is_server_public = false

M.downloads = {}
M.downloading = false
M.downloads_status = {}
M.downloads_received = {}
M.download_start_time = 0
M.download_total_bytes = 0
M.downloaded_bytes = 0
M.download_queue = {}

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
  ping = 0,
  time_offset = 0
}

local CHUNK_SIZE = 65000  -- Safe size under 65536 limit

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
  if not str or #str < 4 then return 0 end
  local b1, b2, b3, b4 = str:byte(1, 4)
  return bit.bor(
      bit.lshift(b4, 24),
      bit.lshift(b3, 16),
      bit.lshift(b2, 8),
      b1
  )
end

local function cancel_download()
for name, file_handle in pairs(M.downloads) do
     file_handle:close()
     
     -- Delete partial file
     local file_path = "/kissmp_mods/" .. name
     if FS:fileExists(file_path) then
       FS:removeFile(file_path)
     end
  end

  -- Clear the tables so dead file handles aren't reused
  M.downloads = {}
  M.downloads_status = {}
  M.downloads_received = {}
  M.downloading = false
  M.download_start_time = 0
  M.download_total_bytes = 0
  M.downloaded_bytes = 0
  M.download_queue = {}
end

local function disconnect(data)
  local text = "Disconnected!"
  if data then
    text = text.." Reason: "..data
  end
  kissui.chat.add_message(text)
  M.connection.connected = false
  
  if vehiclemanager then
    vehiclemanager.loading_map = false
  end
  kissui.show_download = false

  if M.connection.tcp then
    M.connection.tcp:close()
    M.connection.tcp = nil
  end

  cancel_download()

  -- -- Delete the 3D player models from world memory
  -- for _, v in pairs(kissplayers.players) do
  --   if v then v:delete() end
  -- end
  -- for _, v in pairs(kissplayers.players_in_cars) do
  --   if v then v:delete() end
  -- end

  M.players = {}
  kissplayers.players = {}
  kissplayers.player_transforms = {}
  kissplayers.players_in_cars = {}
  kissplayers.player_heads_attachments = {}
  kissrichpresence.update()
  
  if getMissionFilename() ~= "" then
    returnToMainMenu()
  end
end

local function handle_player_info(player_info)
  M.players[player_info.id] = player_info
end

local function check_lua(l)
  local filters = {"FS", "check_lua", "handle_lua", "handle_vehicle_lua", "network =", "network=", "message_handlers", "io%.write", "io%.open", "io%.close", "fileOpen", "fileExists", "removeDirectory", "removeFile", "io%."}
  for k, v in pairs(filters) do
    if string.find(l, v) ~= nil then
      kissui.chat.add_message("Possibly malicious lua command has been send, rejecting. Found: "..v)
      return false
    end
  end
  return true
end

local function handle_lua(data)
  if M.is_server_public then
    log("W", "kissmp.network.handle_lua", "Blocked arbitrary GE Lua command from public server.")
    return
  end

  if check_lua(data) then
    Lua:queueLuaCommand(data)
  end
end

local function handle_vehicle_lua(data)
  if M.is_server_public then
    log("W", "kissmp.network.handle_vehicle_lua", "Blocked arbitrary vehicle Lua command from public server.")
    return
  end

  local id = data[1]
  local lua = data[2]
  local id = vehiclemanager.id_map[id or -1] or 0
  local vehicle = getObjectByID(id)
  if vehicle and check_lua(lua) then
    vehicle:queueLuaCommand(lua)
  end
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
  if kissplayers.players_in_cars[id] then
    kissplayers.delete_player_head(id)
  end

  -- Delete the 3D player models from world memory
  if kissplayers.players[id] then
    kissplayers.players[id]:delete()
    kissplayers.players[id] = nil
  end
  kissplayers.player_transforms[id] = nil
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
    log("E", "kissmp.network.send_data", "Sending raw data is not implemented. Please report to KissMP developers. Code: "..raw_data)
    return
  end
  if not M.connection.connected then return -1 end
  local data = ""
  if type(raw_data) == "string" then
    data = raw_data
  else
    data = jsonEncode(raw_data)
  end
  local data_size = #data
  -- Auto-chunk if data is too large
  if data_size > CHUNK_SIZE then
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

      local len = ffi.string(ffi.new("uint32_t[?]", 1, {#chunk_data}), 4)
      M.connection.tcp:send(string.char(1)..len)
      M.connection.tcp:send(chunk_data)
    end

    return 0
  end

  -- Send normally
  local len = ffi.string(ffi.new("uint32_t[?]", 1, {data_size}), 4)
  reliable = reliable and 1 or 0
  M.connection.tcp:send(string.char(reliable)..len)
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
  local secret = server_identifier..M.base_secret
  return hashStringSHA1(secret)
end

local function change_map(map)
  -- if FS:fileExists(map) or FS:directoryExists(map) then
  --   vehiclemanager.loading_map = true
  --   freeroam_freeroam.startFreeroam(map)
  -- else
  --   kissui.chat.add_message("Map file doesn't exist. Check if mod containing map is enabled", kissui.COLOR_RED)
  --   disconnect()
  -- end
  vehiclemanager.loading_map = true
  freeroam_freeroam.startFreeroam(map)
end

local function connect(addr, player_name, is_public)
  M.is_server_public = is_public or false

  if M.connection.connected then
    disconnect()
  elseif M.connection.tcp then
    M.connection.tcp:close()
    M.connection.tcp = nil
  end

  M.players = {}
  M.download_start_time = 0
  M.download_queue = {}
  M.download_total_bytes = 0
  M.downloaded_bytes = 0

  addr = sanitize_addr(addr)
  log("I", "kissmp.network.connect", "Connecting to "..addr.."...")
  kissui.chat.add_message("Connecting to "..addr.."...")
  M.connection.tcp = socket.tcp()
  M.connection.tcp:settimeout(3.0)
  M.connection.tcp:connect("127.0.0.1", "7894")

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
    kissui.chat.add_message("Failed to confirm connection. Check if bridge is running.", kissui.COLOR_RED)
    return
  end

  -- Ignore message type
  M.connection.tcp:receive(1)

  local len, _, _ = M.connection.tcp:receive(4)
  len = bytesToU32(len)
  local received, _, _ = M.connection.tcp:receive(len)
  local server_info = jsonDecode(received).ServerInfo
  if not server_info then
    log("E", "kissmp.network.connect", "Failed to fetch server info. Aborting.")
    return
  end
  log("I", "kissmp.network.connect", "Server name: "..server_info.name)
  log("I", "kissmp.network.connect", "Player count: "..server_info.player_count)

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
      client_version = version.VERSION
    }
  }
  send_data(client_info, true)

  kissmods.set_mods_list(server_info.mods)
  kissmods.update_status_all()

  local missing_mods = {}
  local mod_names = {}
  local available_mods = {}
  local total_missing_bytes = 0
  for _, mod in pairs(kissmods.mods) do
    table.insert(mod_names, mod.name)
    if mod.status ~= "ok" then
      table.insert(missing_mods, mod.name)
      M.downloads_status[mod.name] = {name = mod.name, progress = 0}
      total_missing_bytes = total_missing_bytes + (mod.size or 0)
    else
      table.insert(available_mods, mod.name)
    end
  end

  M.download_total_bytes = total_missing_bytes
  M.downloaded_bytes = 0
 
  kissmods.deactivate_all_mods()
  if #available_mods > 0 then
    kissmods.mount_mods(available_mods)
  end
  for k, v in pairs(missing_mods) do
    log("I", "kissmp.network.connect", "Missing Mod "..k..": "..v)
  end
  if #missing_mods > 0 then
    -- Do not allow public servers to force mod downloads
    if M.is_server_public then
      kissui.chat.add_message("Connection rejected: Missing mods.", kissui.COLOR_RED)
      disconnect()
      return
    else
      M.download_queue = missing_mods
      local next_mod = table.remove(M.download_queue, 1)
      if next_mod then
        send_data({ RequestMods = { next_mod } }, true)
      end
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

local function on_finished_download()
  M.download_start_time = 0
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

local function onUpdate(dt)
  if not M.connection.connected then return end
  if M.connection.timer < M.connection.heartbeat_time then
    M.connection.timer = M.connection.timer + dt
  else
    M.connection.timer = 0
    send_ping()
  end

  local packets_processed = 0
  local max_packets_per_update = 64

  while packets_processed < max_packets_per_update do
    local msg_type, err = M.connection.tcp:receive(1)
    if not msg_type then
      if err == "closed" then
        disconnect("Connection lost")
      end
      break
    end
    packets_processed = packets_processed + 1

    M.connection.tcp:settimeout(5.0)

    if string.byte(msg_type) == 1 then
      local len_b = M.connection.tcp:receive(4)
      if not len_b then
        M.connection.tcp:settimeout(0.0)
        break
      end

      local len = bytesToU32(len_b)
      local data, _, _ = M.connection.tcp:receive(len)
      M.connection.tcp:settimeout(0.0)
      if not data then break end

      local data_decoded = jsonDecode(data)
      if data_decoded then
        for k, v in pairs(data_decoded) do
          if message_handlers[k] then
            message_handlers[k](v)
          end
        end
      end

    elseif string.byte(msg_type) == 0 then -- Binary data
      if M.is_server_public then
        kissui.chat.add_message("Connection rejected: Server tried to download a mod.", kissui.COLOR_RED)
        disconnect()
        return
      end

      if M.download_start_time == 0 then
        M.download_start_time = socket.gettime()
      end

      local name_b = M.connection.tcp:receive(4)
      if not name_b then
        M.connection.tcp:settimeout(0.0)
        break
      end

      M.downloading = true
      kissui.show_download = true

      local len_n = bytesToU32(name_b)
      local name, _, _ = M.connection.tcp:receive(len_n)
      local chunk_n_b = M.connection.tcp:receive(4)
      local chunk_a_b = M.connection.tcp:receive(4)
      local read_size_b = M.connection.tcp:receive(4)

      if not name or not chunk_n_b or not chunk_a_b or not read_size_b then
        M.connection.tcp:settimeout(0.0)
        break
      end

      local chunk_n = bytesToU32(chunk_n_b)
      local chunk_a = bytesToU32(chunk_a_b)
      local read_size = bytesToU32(read_size_b)
      local file_length = chunk_a
      local file_data, _, _ = M.connection.tcp:receive(read_size)

      M.connection.tcp:settimeout(0.0)
      if not file_data then break end

      if not M.downloads_received[name] then
        M.downloads_received[name] = 0
      end
      M.downloads_received[name] = M.downloads_received[name] + read_size
      M.downloaded_bytes = M.downloaded_bytes + read_size
      if M.download_total_bytes > 0 and M.downloaded_bytes > M.download_total_bytes then
        M.downloaded_bytes = M.download_total_bytes
      end

      M.downloads_status[name] = {
        name = name,
        progress = 0
      }
      M.downloads_status[name].progress = M.downloads_received[name] / file_length

      local file = M.downloads[name]
      if not file then
        file = kissmods.open_file(name)
        M.downloads[name] = file
      end

      if file and file_data then
        file:write(file_data)
      else
        kissui.chat.add_message("Error: Could not write file to disk. Check permissions or disk space.", kissui.COLOR_RED)
        disconnect("File write error")
        return
      end

      if M.downloads_received[name] >= file_length then
        if M.downloads[name] then
          M.downloads[name]:close()
          M.downloads[name] = nil
        end

        kissmods.mount_mod(name)
        M.downloads_status[name] = nil
        M.downloads_received[name] = nil

        if #M.download_queue > 0 then
          local next_mod = table.remove(M.download_queue, 1)
          if next_mod then
            send_data({ RequestMods = { next_mod } }, true)
          end
        else
          M.downloading = false
          kissui.show_download = false
          M.downloaded_bytes = M.download_total_bytes
          on_finished_download()
        end
      end

    elseif string.byte(msg_type) == 2 then
      local len_b = M.connection.tcp:receive(4)
      if not len_b then
        M.connection.tcp:settimeout(0.0)
        break
      end

      local len = bytesToU32(len_b)
      local reason, _, _ = M.connection.tcp:receive(len)
      M.connection.tcp:settimeout(0.0)
      disconnect(reason)
      break

    else
      M.connection.tcp:settimeout(0.0)
    end
  end
end

local function get_client_id()
  return M.connection.client_id
end

M.get_client_id = get_client_id
M.connect = connect
M.disconnect = disconnect
M.cancel_download = cancel_download
M.send_data = send_data
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded

return M
