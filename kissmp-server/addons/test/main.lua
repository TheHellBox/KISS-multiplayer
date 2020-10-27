hooks.register(
  "OnStdIn",
  function(input)
    if input == "/list_vehicles" then
      for vehicle_id, vehicle in pairs(vehicles) do
        local position = vehicle.transform:getPosition()
        print("Vehicle "..vehicle_id..": "..position[1]..", "..position[2]..", "..position[3])
      end
    end
  end
)

hooks.register(
  "OnChat",
  function(client_id, message)
    if message == "/home" then
      local vehicle_id = connections[client_id]:getCurrentVehicle()
      if vehicles[vehicle_id] then
        vehicles[vehicle_id]:setPositionRotation(0, 0, 0, 0, 0, 0, 1)
      end
    end
  end
)
