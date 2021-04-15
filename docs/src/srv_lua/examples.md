```lua
function string.startswith(input, start)
   return string.sub(input,1,string.len(start))==start
end

hooks.register("OnChat", "HomeCommand", function(client_id, message)
    local vehicle_id = connections[client_id]:getCurrentVehicle()
    if not vehicles[vehicle_id] then return end
    local vehicle = vehicles[vehicle_id]
    if message == "/home" then
      vehicle:setPositionRotation(0, 0, 0, 0, 0, 0, 1)
    end
    if message == "/reset" then
      vehicle:reset()
    end
    if message == "/remove" then
      vehicle:remove()
    end
    if message == "/kick_me" then
      connections[client_id]:kick("Kick reason")
    end
    if string.startswith(message, "/send_me_lua") then
      local message = message:gsub("%/send_me_lua", "")
      connections[client_id]:sendLua(message)
    end
    if string.startswith(message, "/send_me_msg") then
      local message = message:gsub("%/send_me_msg", "")
      connections[client_id]:sendChatMessage(message)
    end
end)
```

```lua
local vote = {
  victim = nil,
  votes = {},
  end_time = 0
}

local function startswith(input, start)
   return string.sub(input,1,string.len(start))==start
end

local function count_players()
  local i = 0
  for _, _ in pairs(connections) do
    i = i + 1
  end
  return i
end

hooks.register("OnChat", "VoteKick", function(client_id, message)
    local initiator = connections[client_id]
    if startswith(message, "/votekick") then
      if not vote.victim then
        local victim = message:gsub("%/votekick ", "")
        for _, client in pairs(connections) do
          if victim == client:getName() then
            vote.victim = client:getID()
            vote.end_time = os.clock() + 30
            send_message_broadcast(initiator:getName().." has started a vote to kick "..client:getName())
            send_message_broadcast("Type /vote to vote")
            local votes_needed = count_players() / 2
            send_message_broadcast(math.floor(votes_needed).." votes are needed")
          else
            initiator:sendChatMessage("No such player")
          end
        end
      else
        initiator:sendChatMessage("Wait until the current vote ends")
      end
    end
    if startswith(message, "/vote") then
      if not vote.votes[initiator:getID()] then
        vote.votes[initiator:getID()] = true
      else
        initiator:sendChatMessage("You have already voted!")
      end
    end
end)

hooks.register("Tick", "VoteTimer", function(client_id, message)
    if vote.victim and (os.clock() > vote.end_time) then
      local votes_count = 0
      for _, _ in pairs(vote.votes) do
        votes_count = votes_count + 1
      end
      if votes_count > (count_players() / 2) then
        local victim = connections[vote.victim]
        if victim then
          victim:kick("You have been kicked by vote results")
          send_message_broadcast(victim:getName().." has been kicked by vote results")
        end
      else
        send_message_broadcast("Vote has failed")
      end
      vote.victim = nil
      vote.votes = {}
    end
end)
```

```lua
hooks.register("OnStdIn", "ListVehiclesCommand", function(input)
    if input == "/list_vehicles" then
      for vehicle_id, vehicle in pairs(vehicles) do
        local position = vehicle:getTransform():getPosition()
        print("Vehicle "..vehicle_id..": "..position[1]..", "..position[2]..", "..position[3])
      end
    end
end)
```
