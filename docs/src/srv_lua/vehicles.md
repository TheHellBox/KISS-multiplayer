# Vehicles

A **vehicle object** represents a vehicle that was spawned by a client.

Vehicle objects are stored in the global table `vehicles` and a specific vehicle can be obtained using its vehicle ID with `vehicles[vehicle_id]`.


**Vehicle objects have the following methods:**
- getTransform()
  - Returns: Table ([Transform](transform.html))
- getData()
  - Returns: Table ([Vehicle Data](vehicle_data.html))
- remove()
  - Returns: null
- reset()
  - Returns: null
- setPositionRotation(x, y, z, xr, yr, zr, w)
  - **Note:** Rotation is in quaternion form.
  - Returns: null
- sendLua(string lua_command)
  - Returns: null