Here's a simple admin system.
It's probably not suitable for big servers, and only serves as an example, but it can still be used
in it's original form
```lua
KSA = {}

KSA.ban_list = {}
KSA.player_roles = {}

KSA.commands = {
  kick = {
    roles = {admin = true, superadmin = true},
    exec = function(executor, args)
      if not args[1] then executor:sendChatMessage("No arguments provided") end
      for id, client in pairs(connections) do
        if client:getName() == args[1] then
          client:kick("You have been kicked. Reason: "..(args[2] or "No reason provided"))
          return
        end
      end
    end
  },
  ban = {
    roles = {admin = true, superadmin = true},
    exec = function(executor, args)
      if not args[1] then executor:sendChatMessage("No arguments provided") end
      for id, client in pairs(connections) do
        if client:getName() == args[1] then
          KSA.ban(client:getSecret(), client:getName(), client:getID(), tonumber(args[2]) or math.huge)
          return
        end
      end     
    end
  },
  promote = {
    roles = {superadmin = true},
    exec = function(executor, args)
      if not args[1] then executor:sendChatMessage("No arguments provided") end
      for id, client in pairs(connections) do
        if client:getName() == args[1] then
          KSA.promote(client:getSecret(), args[2] or "user")
          return
        end
      end
    end
  }
}

  -- Created by Dummiesman
local function cmd_parse(cmd)
  local parts = {}
  local len = cmd:len()
  local escape_sequence_stack = 0
  local in_quotes = false

  local cur_part = ""
  for i=1,len,1 do
     local char = cmd:sub(i,i)
     if escape_sequence_stack > 0 then escape_sequence_stack = escape_sequence_stack + 1 end
     local in_escape_sequence = escape_sequence_stack > 0
     if char == "\\" then
        escape_sequence_stack = 1
     elseif char == " " and not in_quotes then
        table.insert(parts, cur_part)
        cur_part = ""
     elseif char == '"'and not in_escape_sequence then
        in_quotes = not in_quotes
     else
        cur_part = cur_part .. char
     end
     if escape_sequence_stack > 1 then escape_sequence_stack = 0 end
  end
  if cur_part:len() > 0 then
    table.insert(parts, cur_part)
  end
  return parts
end

local function load_roles()
  local file = io.open("./ksa_roles.json", "r")
  if not file then return end
  KSA.player_roles = decode_json(file:read("*a"))
end

local function save_roles()
  local file = io.open("./ksa_roles.json", "w")
  local content = encode_json_pretty(KSA.player_roles)
  if not content then return end
  file:write(content)
end

local function load_banlist()
  local file = io.open("./ksa_banlist.json", "r")
  if not file then return end
  KSA.ban_list = decode_json(file:read("*a"))
end

local function save_banlist()
  local file = io.open("./ksa_banlist.json", "w")
  local content = encode_json_pretty(KSA.ban_list)
  if not content then return end
  file:write(content)
end

function KSA.ban(secret, name, client_id, time)
  local time = time or math.huge()
  KSA.ban_list[secret] = {
    name = name,
    unban_time = os.time() + (time * 60)
  }
  connections[client_id]:kick("You've been banned on this server.")
  save_banlist()
end

function KSA.unban(secret)
  KSA.ban_list[secret] = nil
  save_banlist()
end

function KSA.promote(secret, new_role)
  KSA.player_roles[secret] = new_role
  save_roles()
end

hooks.register("OnPlayerConnected", "CheckBanList", function(client_id)
    local secret = connections[client_id]:getSecret()
    local ban = KSA.ban_list[secret]
    if not ban then return end
    local remaining = ban.unban_time - os.time()
    if remaining < 0 then
      KSA.unban(secret)
      return
    end
    connections[client_id]:kick("You've been banned on this server. Time remaining: "..tostring(remaining / 60).." min")
end)

hooks.register("OnStdIn", "KSA_Run_Lua", function(str)
    if string.sub(str, 1, 7) == "run_lua" then
      load(string.sub(str, 9, #str))()
    end
end)

hooks.register("OnStdIn", "KSA_Promote", function(str)
    if not string.sub(str, 1, 9) == "set_super" then return end
    local target = string.sub(str, 11, #str)
    print(target)
    for id, client in pairs(connections) do
      if client:getName() == target then
        KSA.promote(client:getSecret(), "superadmin")
      end
    end
end)

hooks.register("OnChat", "KSA_Process_Commands", function(client_id, str)
    if not string.sub(str, 1, 4) == "/ksa" then return end
    local args = cmd_parse(str, " ")
    table.remove(args, 1)
    local base = table.remove(args, 1)
    local executor = connections[client_id]
    local command = KSA.commands[base]
    if not command.roles[KSA.player_roles[executor:getSecret()] or "user"] then
      executor:sendChatMessage("KSA: You're not allowed to use this command")
      return
    end
    if not command then
      executor:sendChatMessage("KSA: Command not found")
      return
    end
    command.exec(executor, args)
    return ""
end)

load_roles()
load_banlist()
```
