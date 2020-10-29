local M = {}
local http = require("socket.http")

local timer = 0

local function update(dt)
  if timer < 1 then
    timer = timer + dt
    return
  end
  timer = 0
  if (not network.connection.server_info) or (not network.connection.connected) then
    local _, _, _  = http.request("http://127.0.0.1:3693/rich_presence/none")
    return
  end

  local _, _, _  = http.request("http://127.0.0.1:3693/rich_presence/"..network.connection.server_info.name)
end

--M.onUpdate = update
return M
