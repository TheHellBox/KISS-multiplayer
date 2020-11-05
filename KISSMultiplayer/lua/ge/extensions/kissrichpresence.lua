local M = {}
local http = require("socket.http")

local function update()
  if (not network.connection.server_info) or (not network.connection.connected) then
    local _, _, _  = http.request("http://127.0.0.1:3693/rich_presence/none")
    return
  end

  local _, _, _  = http.request("http://127.0.0.1:3693/rich_presence/"..network.connection.server_info.name)
end

M.update = update
return M
