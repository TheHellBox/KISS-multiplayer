## Hooks
You can register a hook by running
```lua
hooks.register("HookName", "Subname", function(arguments)
    return value
end)
```
Keep in mind that the subname has to be unique.

**Default hooks include:**
- OnChat(client_id: number, message: string)
  `returns string - modified message` 
  
- Tick()
- OnStdIn(input: string)
- OnVehicleRemoved(vehicle_id: number, client_id: number)
- OnVehicleSpawned(vehicle_id: number, client_id: number)
- OnVehicleResetted(vehicle_id: number, client_id: number)
- OnPlayerConnected(client_id: number)
- OnPlayerDisconnected(client_id: number)
