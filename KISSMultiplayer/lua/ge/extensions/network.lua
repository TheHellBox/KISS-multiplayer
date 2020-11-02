local M = {}
M.downloading = false
M.downloads_status = {}

local current_download = nil

local socket = require("socket")
local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")
local ping_send_time = 0

M.players = {}
M.socket = socket

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

local MESSAGETYPE_TRANSFORM = 0
local MESSAGETYPE_VEHICLE_SPAWN = 1
local MESSAGETYPE_ELECTRICS = 2
local MESSAGETYPE_GEARBOX = 3
local MESSAGETYPE_NODES = 4
local MESSAGETYPE_VEHICLE_REMOVE = 5
local MESSAGETYPE_VEHICLE_RESET = 6
local MESSAGETYPE_CLIENT_INFO= 7
local MESSAGETYPE_CHAT = 8
local FILE_TRANSFER = 9
local DISCONNECTED = 10
local MESSAGETYPE_LUA = 11
local MESSAGETYPE_PLAYERINFO = 12
local MESSAGETYPE_META_UPDATE = 14
local MESSAGETYPE_ELECTRICS_UNDEFINED = 15
local PONG = 254

local message_handlers = {}

local ping_calculator = {
  samples = {},
  current_sample = 1,
}

ping_calculator.get = function(new_sample)
  if ping_calculator.current_sample < 10 then
    ping_calculator.samples[ping_calculator.current_sample] = new_sample
  else
    ping_calculator.current_sample = 0
  end
  local sum = 0
  local n = 0
  for _, v in pairs(ping_calculator.samples) do
    sum = sum + v
    n = n + 1
  end
  return sum / n
end

local function disconnect(data)
  local text = "Disconnected!"
  if data then
    text = text.." Reason: "..data
  end
  kissui.add_message(text)
  M.connection.connected = false
  M.players = {}
end

local function handle_disconnected(data)
  disconnect(data)
end

local function handle_file_transfer(data)
  kissui.show_download = true
  local file_len = ffi.cast("uint32_t*", ffi.new("char[?]", 4, data:sub(1, 4)))[0] 
  local file_name = data:sub(5, #data)
  local chunks = math.floor(file_len / 4096)
  
  current_download = {
    file_len = file_len,
    file_name = file_name,
    chunks = chunks,
    last_chunk = file_len - chunks * 4096,
    current_chunk = 0,
    file = kissmods.open_file(file_name)
  }
  M.downloading = true
end

local function handle_player_info(data)
  local player_info = messagepack.unpack(data)
  if player_info then
    local player_info = {
      name = player_info[1],
      id = player_info[2],
      current_vehicle = player_info[3],
      ping = player_info[4]
    }
    M.players[player_info.id] = player_info
  end
end

local function handle_lua(data)
  Lua:queueLuaCommand(data)
end

local function handle_pong(data)
  local server_time = ffi.cast("double*", ffi.new("char[?]", 9, data))[0]
  local local_time = socket.gettime()
  local ping = local_time - ping_send_time
  if ping > 1.5 then return end
  local ping = ping_calculator.get(ping)
  local time_diff = server_time - local_time + (ping / 2)
  M.connection.time_offset = time_diff
  M.connection.ping = ping * 1000
end

local function onExtensionLoaded()
  message_handlers[MESSAGETYPE_TRANSFORM] = kisstransform.update_vehicle_transform
  message_handlers[MESSAGETYPE_VEHICLE_SPAWN] = vehiclemanager.spawn_vehicle
  message_handlers[MESSAGETYPE_ELECTRICS] = vehiclemanager.update_vehicle_electrics
  message_handlers[MESSAGETYPE_GEARBOX] = vehiclemanager.update_vehicle_gearbox
  message_handlers[MESSAGETYPE_VEHICLE_REMOVE] = vehiclemanager.remove_vehicle
  message_handlers[MESSAGETYPE_VEHICLE_RESET] = vehiclemanager.reset_vehicle
  message_handlers[MESSAGETYPE_CHAT] = kissui.add_message
  message_handlers[FILE_TRANSFER] = handle_file_transfer
  message_handlers[DISCONNECTED] = handle_disconnected
  message_handlers[MESSAGETYPE_LUA] = handle_lua
  message_handlers[MESSAGETYPE_PLAYERINFO] = handle_player_info
  message_handlers[MESSAGETYPE_META_UPDATE] = vehiclemanager.update_vehicle_meta
  message_handlers[MESSAGETYPE_ELECTRICS_UNDEFINED] = vehiclemanager.electrics_diff_update
  message_handlers[PONG] = handle_pong
end

local function send_data(data_type, reliable, data)
  if not M.connection.connected then return -1 end
  local len = #data
  local len = ffi.string(ffi.new("uint32_t[?]", 1, {len}), 4)
  if reliable then
    reliable = 1
  else
    reliable = 0
  end
  M.connection.tcp:send(string.char(reliable)..string.char(data_type)..len)
  M.connection.tcp:send(data)
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

local function connect(addr, player_name)
  print("Connecting...")
  addr = sanitize_addr(addr)
  kissui.add_message("Connecting to "..addr.."...")
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
      kissui.add_message("Connection failed.")
      return
    end
  else
    kissui.add_message("Failed to confirm connection. Check if bridge is running.")
    return
  end

  local _ = M.connection.tcp:receive(1)
  local len, _, _ = M.connection.tcp:receive(4)
  local len = ffi.cast("uint32_t*", ffi.new("char[?]", #len + 1, len))
  local len = len[0]

  local received, _, _ = M.connection.tcp:receive(len)
  local server_info = jsonDecode(received)
  if not server_info then
    print("Failed to fetch server info")
    return
  end
  print("Server name: "..server_info.name)
  print("Player count: "..server_info.player_count)

  M.connection.tcp:settimeout(0.0)
  M.connection.connected = true
  M.connection.client_id = server_info.client_id
  M.connection.server_info = server_info
  M.connection.tickrate = server_info.tickrate

  kissui.add_message("Connected!");

  local client_info = {
    name = player_name
  }

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
  kissmods.mount_mods(mod_names)
  
  -- Request mods
  send_data(9, true, jsonEncode(missing_mods))
  send_data(MESSAGETYPE_CLIENT_INFO, true, jsonEncode(client_info))
 
  if server_info.map ~= "any" and #missing_mods == 0 then
    freeroam_freeroam.startFreeroam(server_info.map)
    vehiclemanager.loading_map = true
  end
end

local function send_messagepack(data_type, reliable, data)
  local data = messagepack.pack(jsonDecode(data))
  send_data(data_type, reliable, data)
end

local function on_finished_download()
  if M.connection.server_info.map ~= "any" then
    vehiclemanager.loading_map = true
    freeroam_freeroam.startFreeroam(M.connection.server_info.map)
  end
end

local function send_ping()
  ping_send_time = socket.gettime()
  -- Btw, this is actually used to send player's ping value
  local ping = ffi.string(ffi.new("uint32_t[?]", 1, {math.floor(M.connection.ping)}), 4)
  send_data(254, false, ping)
end

local function cancel_download()
  if not current_download then return end
  io.close(current_download.file)
  current_download = nil
  M.downloading = false
end

local function continue_download()
  send_ping()
  kissui.show_download = true
  
  local packets = 0
  local attempts = 0
  while current_download.current_chunk < current_download.chunks do
    M.downloads_status[current_download.file_name].progress = current_download.current_chunk / current_download.chunks
    M.connection.tcp:settimeout(2.0)
    local data, _, _ = M.connection.tcp:receive(4096)
    if data then
      attempts = 0
      current_download.file:write(data)
      current_download.current_chunk =  current_download.current_chunk + 1
      packets = packets + 1
      if packets > 10 then
        return
      end
    else
      if attempts > 5 then
        M.downloading = false
        current_download.file:close()
        current_download = nil
        kissui.show_download = false
        kissui.add_message("Download failed, disconnecting.")
        disconnect()
        return
      end
      attempts = attempts + 1
    end
  end
  local data, _, _ = M.connection.tcp:receive(current_download.last_chunk)
  current_download.file:write(data)
  
  M.downloading = false
  current_download.file:close()
  kissmods.update_status(kissmods.mods[current_download.file_name])
  kissmods.mount_mod(current_download.file_name)
  current_download = nil
  
  M.connection.tcp:settimeout(0.0)
  M.connection.mods_left = M.connection.mods_left - 1
  if M.connection.mods_left < 1 then
    M.downloads_status = nil
    kissui.show_download = false
    on_finished_download()
  end
end

local function onUpdate(dt)
  if not M.connection.connected then return end

  if M.downloading then
    continue_download()
    return
  end

  if M.connection.timer < M.connection.heartbeat_time then
    M.connection.timer = M.connection.timer + dt
  else
    M.connection.timer = 0
    send_ping()
  end

  while true do
    local received, _, _ = M.connection.tcp:receive(1)
    if not received then break end
    M.connection.tcp:settimeout(5.0)
    local data_type = string.byte(received)
    --print(data_type)
    local data = M.connection.tcp:receive(4)
    local len = ffi.cast("uint32_t*", ffi.new("char[?]", 5, data))

    local data, _, _ = M.connection.tcp:receive(len[0])
    M.connection.tcp:settimeout(0.0)
    message_handlers[data_type](data)

    if data_type == FILE_TRANSFER then
      break
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
M.send_messagepack = send_messagepack
M.onExtensionLoaded = onExtensionLoaded

return M
