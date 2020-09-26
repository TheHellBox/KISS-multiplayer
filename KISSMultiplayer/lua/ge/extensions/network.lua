local M = {}

local socket = require("socket")
local connection = {
  tcp = nil,
  connected = false,
  client_id = 0,
  heartbeat_time = 1,
  timer = 0,
  timeout_buffer = nil
}

local function connect(addr)
  print("Connecting...")
  connection.tcp = socket.tcp()
  connection.tcp:settimeout(5.0)
  local connected, err = connection.tcp:connect("127.0.0.1", "7894")
  -- Send server address to the bridge
  local addr_lenght = ffi.string(ffi.new("uint32_t[?]", 1, {#addr}), 4)
  connection.tcp.send(addr_lenght)
  connection.tcp.send(addr)
  local _ = connection.tcp:receive(1)
  local len, _, _ = connection.tcp:receive(4)
  local len = ffi.cast("uint32_t*", ffi.new("char[?]", #len, len))
  local len = len[0]
  print(len)
  local received, _, _ = connection.tcp:receive(len)
  local server_info = jsonDecode(received)
  if not server_info then
    print("Failed to fetch server info")
    return
  end
  print("Server name: "..server_info.name)
  print("Player count: "..server_info.player_count)
  connection.tcp:settimeout(0.0)
  connection.connected = true
  connection.client_id = server_info.client_id
end

local function send_data(data_type, reliable, data)
  if not connection.connected then return -1 end
  local len = #data
  local len = ffi.string(ffi.new("uint32_t[?]", 1, {len}), 4)
  if reliable then
    reliable = 1
  else
    reliable = 0
  end
  connection.tcp:send(string.char(reliable)..string.char(data_type)..len)
  connection.tcp:send(data)
end

local function onUpdate(dt)
  if not connection.connected then return end
  if connection.timer < connection.heartbeat_time then
    connection.timer = connection.timer + dt
  else
    connection.timer = 0
    send_data(254, false, "hi")
  end
  while true do
    local received, _, _ = connection.tcp:receive(1)
    if not received then break end
    connection.tcp:settimeout(5.0)
    local data_type = string.byte(received)
    local data = connection.tcp:receive(4)
    local len = ffi.cast("uint32_t*", ffi.new("char[?]", #data, data))
    local data, _, _ = connection.tcp:receive(len[0])
    if not data then
      print("Failed to fetch data")
      return
    end
    connection.tcp:settimeout(0.0)
    if data_type == 0 then
      local p = ffi.new("char[?]", #data, data)
      local ptr = ffi.cast("float*", p)
      --ptr = {0, 0, 0, 0, 0, 0, 0, 0, 0}
      local transform = {}
      transform.position = {ptr[0], ptr[1], ptr[2]}
      transform.rotation = {ptr[3], ptr[4], ptr[5], ptr[6]}
      transform.owner = ptr[7]
      tranform.generation = ptr[8]
      --print(ptr[0], ptr[1], ptr[2], ptr[3], ptr[4], ptr[5], ptr[6], ptr[7])
      vehiclemanager.update_vehicle_transform(transform)
    elseif data_type == 1 then
      local decoded = jsonDecode(data)
      vehiclemanager.spawn_vehicle(decoded)
    end
  end
end

local function get_client_id()
  return connection.client_id
end

M.get_client_id = get_client_id
M.connect = connect
M.send_data = send_data
M.onUpdate = onUpdate

return M
