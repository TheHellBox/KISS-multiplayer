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
