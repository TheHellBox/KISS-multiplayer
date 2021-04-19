-- This module maintains the server listing and favorites.
-- Favorites are pre-loaded.
local M = {}

local http = require("socket.http")
local VERSION = require("kissmp.version")

local server_list = {}
local favorite_servers = {}

local master_addr = "http://kissmp.online:3692/"

-- Commit favorites to disk
local function save_favorites()
  local file = io.open("./settings/kissmp_favorites.json", "w")
  file:write(jsonEncode(favorite_servers))
  io.close(file)
end

-- Load favorites from disk
local function load_favorites()
  local file = io.open("./settings/kissmp_favorites.json", "r")
  if file then
    local content = file:read("*a")
    favorite_servers = jsonDecode(content) or {}
    io.close(file)
  end
end

--[[ This function does not seem to have a purpose at the moment

local function update_favorites()
  local update_count = 0
  for addr, server in pairs(favorite_servers) do
    if not server.added_manually then
      local server_from_list = server_list[addr]
      local server_found_in_list = server_from_list ~= nil
      
      if server_found_in_list then
        server.name = server_from_list.name
        server.description = server_from_list.description
        update_count = update_count + 1
      end
    end
  end
  
  if update_count > 0 then 
    save_favorites()
  end
end
 ]]

local function add_server_to_favorites(addr, name, description, manual)
  favorite_servers[addr] = {
    name = name,
    description = description,
    added_manually = manual
  }
  save_favorites()
end


local function remove_server_from_favorites(addr)
  favorite_servers[addr] = nil
  save_favorites()
end

-- Returns true on success, or false with a string explaining why
local function refresh_server_list()
  local b, _, _  = http.request("http://127.0.0.1:3693/check")
  if not b or b ~= "ok" then
    return false, "Can not contact bridge. Is it running?"
  else
    b, _, _  = http.request("http://127.0.0.1:3693/"..master_addr.."/"..VERSION)
    if not b then
      return false, "Unable to reach the master server. Try again later."
    else
      -- Other parts of the project use the server_list by reference, so don't break it.
      for k in pairs(server_list) do
        server_list[k] = nil
      end
      for key, value in pairs(jsonDecode(b) or {}) do
        server_list[key] = value
      end
    end
  end
  return true, nil
end

M.server_list = server_list
M.favorite_servers = favorite_servers
M.add_server_to_favorites = add_server_to_favorites
M.remove_server_from_favorites = remove_server_from_favorites
M.refresh_server_list = refresh_server_list

load_favorites()

return M