Connection object represents a player connected to the server.

Connections are stored in global table `connections` and can be accessed with `connections[client_id]` 

**List of methods an connection object has:**
- getID()
- getIpAddr()
- getSecret()
- getCurrentVehicle()
- getName()
- sendChatMessage(string message)
- kick(string reason)
- sendLua(string lua_command)

`getSecret`
Returns player unique identifier. WARNING: NEVER EXPOSE TO CLIENT SIDE!
