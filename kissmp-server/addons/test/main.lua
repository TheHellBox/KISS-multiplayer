function string.startswith(input, start)
   return string.sub(input,1,string.len(start))==start
end

hooks.register("OnStdIn", "ListVehiclesCommand", function(input)
    if input == "/list_vehicles" then
      for vehicle_id, vehicle in pairs(vehicles) do
        local position = vehicle.transform:getPosition()
        print("Vehicle "..vehicle_id..": "..position[1]..", "..position[2]..", "..position[3])
      end
    end
end)

  -- Used to test most of the API
hooks.register("OnChat", "HomeCommand", function(client_id, message)
    local vehicle_id = connections[client_id]:getCurrentVehicle()
    if not vehicles[vehicle_id] then return end
    local vehicle = vehicles[vehicle_id]
    if message == "/home" then
      if vehicles[vehicle_id] then
        vehicle.setPositionRotation(0, 0, 0, 0, 0, 0, 1)
      end
    end
    if message == "/reset" then
      if vehicles[vehicle_id] then
        vehicle.reset()
      end
    end
    if message == "/remove" then
      if vehicles[vehicle_id] then
        vehicle.remove()
      end
    end
    if message == "/kick_me" then
      connections[client_id]:kick()
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
