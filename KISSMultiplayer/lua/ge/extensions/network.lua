local M = {}
M.downloading = false
M.download_info = {}

local socket = require("socket")
local messagepack = require("lua/common/libs/Lua-MessagePack/MessagePack")

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
  timeout_buffer = nil
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
local MESSAGETYPE_VEHICLEDATA_UPDATE = 13
local MESSAGETYPE_COLORS_UPDATE = 14

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
  local len = ffi.cast("uint32_t*", ffi.new("char[?]", #len, len))
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

  local mod_list = {}
  for k, v in pairs(server_info.mods) do
    table.insert(mod_list, v[1])
  end
  M.connection.mods_left = #mod_list
 
  kissmods.deactivate_all_mods()
  kissmods.mount_mods(mod_list)
  local missing_mods = kissmods.check_mods(server_info.mods)
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

local function continue_download()
  send_data(254, false, "hi")
  kissui.show_download = true
  local packets = 0
  while M.download_info.current_chunk < M.download_info.chunks do
    kissui.download_progress = M.download_info.current_chunk / M.download_info.chunks
    M.connection.tcp:settimeout(2.0)
    local data, _, _ = M.connection.tcp:receive(4096)
    M.download_info.file:write(data or "")
    M.download_info.current_chunk =  M.download_info.current_chunk + 1
    packets = packets + 1
    if packets > 10 then
      return
    end
  end
  local data, _, _ = M.connection.tcp:receive(M.download_info.last_chunk)
  M.download_info.file:write(data)
  kissui.show_download = false
  M.downloading = false
  M.download_info.file:close()
  kissmods.mount_mod(M.download_info.file_name)
  M.connection.tcp:settimeout(0.0)
  M.connection.mods_left = M.connection.mods_left - 1
  if M.connection.mods_left < 1 then
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
    send_data(254, false, "hi")
  end

  while true do
    local received, _, _ = M.connection.tcp:receive(1)
    if not received then break end
    M.connection.tcp:settimeout(5.0)
    local data_type = string.byte(received)
    --print(data_type)
    local data = M.connection.tcp:receive(4)
    local len = ffi.cast("uint32_t*", ffi.new("char[?]", 4, data))

    local data, _, _ = M.connection.tcp:receive(len[0])

    M.connection.tcp:settimeout(0.0)

    if data_type == MESSAGETYPE_TRANSFORM then
      data = data..string.char(1)
      local p = ffi.new("char[?]", #data, data)
      local ptr = ffi.cast("float*", p)
      local transform = {}
      transform.position = {ptr[0], ptr[1], ptr[2]}
      transform.rotation = {ptr[3], ptr[4], ptr[5], ptr[6]}
      transform.velocity = {ptr[7], ptr[8], ptr[9]}
      transform.angular_velocity = {ptr[10], ptr[11], ptr[12]}
      transform.owner = ptr[13]
      transform.generation = ptr[14]
      transform.sent_at = ptr[15]
      kisstransform.update_vehicle_transform(transform)
    elseif data_type == MESSAGETYPE_VEHICLE_SPAWN then
      local decoded = jsonDecode(data)
      if decoded then
        vehiclemanager.spawn_vehicle(decoded)
      end
    elseif data_type == MESSAGETYPE_ELECTRICS then
      vehiclemanager.update_vehicle_electrics(data)
    elseif data_type == MESSAGETYPE_GEARBOX then
      vehiclemanager.update_vehicle_gearbox(data)
    elseif data_type == MESSAGETYPE_NODES then
      vehiclemanager.update_vehicle_nodes(data)
    elseif data_type == MESSAGETYPE_VEHICLE_REMOVE then
      vehiclemanager.remove_vehicle(ffi.cast("uint32_t*", ffi.new("char[?]", 4, data))[0])
    elseif data_type == MESSAGETYPE_VEHICLE_RESET then
      vehiclemanager.reset_vehicle(ffi.cast("uint32_t*", ffi.new("char[?]", 4, data))[0])
    elseif data_type == MESSAGETYPE_CHAT then
      kissui.add_message(data)
    elseif data_type == FILE_TRANSFER then
      kissui.show_download = true
      local file_len = data:sub(1, 4)
      M.download_info.file_len = ffi.cast("uint32_t*", ffi.new("char[?]", 4, file_len))[0]
      M.download_info.file_name = data:sub(5, #data)
      M.download_info.chunks = math.floor(M.download_info.file_len / 4096)
      M.download_info.last_chunk = M.download_info.file_len - M.download_info.chunks * 4096
      M.download_info.current_chunk = 0
      M.download_info.file = kissmods.open_file(M.download_info.file_name)
      M.downloading = true
      break
    elseif data_type == DISCONNECTED then
      kissui.add_message("Disconnected.")
      M.connection.connected = false
    elseif data_type == MESSAGETYPE_LUA then
      Lua:queueLuaCommand(data)
    elseif data_type == MESSAGETYPE_PLAYERINFO then
      local player_info = messagepack.unpack(data)
      if player_info then
        local player_info = {
          name = player_info[1],
          id = player_info[2],
          current_vehicle = player_info[3]
        }
        M.players[player_info.id] = player_info
      end
    elseif data_type == MESSAGETYPE_COLORS_UPDATE then
      vehiclemanager.update_vehicle_colors(data)
    end
  end
end

local function get_client_id()
  return M.connection.client_id
end

M.get_client_id = get_client_id
M.connect = connect
M.send_data = send_data
M.onUpdate = onUpdate
M.send_messagepack = send_messagepack

return M
