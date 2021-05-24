# Connections
A **connection object** represents a player connected to the server.

Connections are stored in the global table `connections` and a specific connection can be obtained using its client ID with `connections[client_id]`.

**List of methods a connection object has:**
- getID()
  - Returns: Integer ([Client ID](connection.html))
- getIpAddr()
  - Returns: String
- getSecret()
  - Note: Returns a client unique identifier. Keep the server identifier the same if you want persistent client secrets between different servers. **WARNING:** NEVER EXPOSE TO CLIENT SIDE!
  - Returns: String
- getCurrentVehicle()
  - Returns: Integer ([Vehicle ID](vehicles.html))
- getName()
  - Returns: String
- sendChatMessage(string message)
  - Returns: null
- kick(string reason)
  - Returns: null
- sendLua(string lua_command)
  - Note: **WARNING**: You should **always** make sure to sanitize any form of user input inside of sendLua to avoid clients being vulnerable to arbitrary code injections.\
  For example `client:sendLua('ui_message("'..message..'")')` would be vulnerable if `message` is `") Evil code here--`.\
  The [admin system example](admin_system_example.html) has an example of sanitization in the `cmd_parse` function.
  - Returns: null