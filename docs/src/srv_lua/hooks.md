## Hooks
You can register a hook by running
```lua
hooks.register("HookName", "Subname", function(arguments)
    return value
end)
```
Keep in mind that subname has to be unique.

**Default hooks include:**
- OnChat(int client_id, string message)
  `returns string - modified message` 
  
- Tick()
- OnStdIn(string input)
- OnVehicleRemoved(vehicle_id, client_id)
- OnVehicleSpawned(vehicle_id, client_id)
- OnVehicleResetted(vehicle_id, client_id)
- OnPlayerConnected(client_id)
- OnPlayerDisconnected(client_id)
