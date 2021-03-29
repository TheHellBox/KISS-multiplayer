local M = {}
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

local FILE_TRANSFER_CHUNK_SIZE = 4096 * 1024;

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

local function disconnect(data)
  local text = "Disconnected!"
  if data then
    text = text.." Reason: "..data
  end
  kissui.add_message(text)
  M.connection.connected = false
  M.connection.tcp:close()
  M.players = {}
  kissrichpresence.update()
  --vehiclemanager.id_map = {}
  --vehiclemanager.ownership = {}
  --vehiclemanager.delay_spawns = false
  --kissui.force_disable_nametags = false
  --Lua:requestReload()
  --kissutils.hooks.clear()
end

local function handle_disconnected(data)
  disconnect(data)
end

local function handle_file_transfer(data)
  kissui.show_download = true
  local file_len = ffi.cast("uint32_t*", ffi.new("char[?]", 5, data:sub(1, 4)))[0]
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

local function handle_lua(data)
  Lua:queueLuaCommand(data)
end

local function handle_vehicle_lua(data)
  local id = data[1]
  local lua = data[2]
  local id = vehiclemanager.id_map[id]
  local vehicle = be:getObjectByID(id)
  if vehicle then
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
end

local function onExtensionLoaded()
  message_handlers.VehicleUpdate = vehiclemanager.update_vehicle
  message_handlers.VehicleSpawn = vehiclemanager.spawn_vehicle
  message_handlers.RemoveVehicle = vehiclemanager.remove_vehicle
  message_handlers.ResetVehicle = vehiclemanager.reset_vehicle
  message_handlers.Chat = kissui.add_message
  message_handlers.SendLua = handle_lua
  message_handlers.PlayerInfoUpdate = handle_player_info
  message_handlers.VehicleMetaUpdate = vehiclemanager.update_vehicle_meta
  message_handlers.Pong = handle_pong
  message_handlers.PlayerDisconnected = handle_player_disconnected
  message_handlers.VehicleLuaCommand = handle_vehicle_lua
  message_handlers.CouplerAttached = vehiclemanager.attach_coupler
  message_handlers.CouplerDetached = vehiclemanager.detach_coupler
  message_handlers.ElectricsUndefinedUpdate = vehiclemanager.electrics_diff_update
end

local function send_data(raw_data, reliable)
  if type(raw_data) == "number" then
    print("NOT IMPLEMENTED. PLEASE REPORT TO KISSMP DEVELOPERS. CODE: "..raw_data)
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
  M.connection.tcp:send(string.char(reliable)..len)
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

local function generate_secret(server_identifier)
  local secret = server_identifier..M.base_secret
  return hashStringSHA1(secret)
end

local function connect(addr, player_name)
  if M.connection.connected then
    disconnect()
  end
  M.players = {}

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
      kissui.add_message("Connection failed.", kissui.COLOR_RED)
      return
    end
  else
    kissui.add_message("Failed to confirm connection. Check if bridge is running.", kissui.COLOR_RED)
    return
  end

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
  print("Server name: "..server_info.name)
  print("Player count: "..server_info.player_count)

  M.connection.tcp:settimeout(0.0)
  M.connection.connected = true
  M.connection.client_id = server_info.client_id
  M.connection.server_info = server_info
  M.connection.tickrate = server_info.tickrate

  local client_info = {
    ClientInfo = {
      name = player_name,
      secret = generate_secret(server_info.server_identifier),
      client_version = {0, 3}
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
  kissmods.mount_mods(mod_names)
  
  -- Request mods
  send_data(9, true, jsonEncode(missing_mods))

  if server_info.map ~= "any" and #missing_mods == 0 then
    freeroam_freeroam.startFreeroam(server_info.map)
    vehiclemanager.loading_map = true
  end
  kissrichpresence.update()
  kissui.add_message("Connected!")
end

local function send_messagepack(data_type, reliable, data)
  local data = data
  if type(data) == "string" then
    data = jsonDecode(data)
  end
  data = messagepack.pack(data)
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
  send_data(
    {
      Ping = math.floor(M.connection.ping),
    },
    false
  )
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
        kissui.add_message("Download failed, disconnecting.", kissui.COLOR_RED)
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
    local data = M.connection.tcp:receive(4)
    if not data then break end
    M.connection.tcp:settimeout(5.0)
    local len = ffi.cast("uint32_t*", ffi.new("char[?]", 5, data))

    local data, _, _ = M.connection.tcp:receive(len[0])
    M.connection.tcp:settimeout(0.0)
    local data_decoded = jsonDecode(data)
    for k, v in pairs(data_decoded) do
      if message_handlers[k] then
        message_handlers[k](v)
      end
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
