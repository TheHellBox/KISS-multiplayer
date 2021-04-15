Vehicle object represents vehicle that was spawned by one of the clients. It has owner, transform, and it's information.
You can acess transform by
```lua
vehicle:getTransform()
```
And data by
```lua
vehicle:getData()
```

**Vehicle object has following methods:**
- getTransform()
- getData()
- remove()
- reset()
- setPositionRotation(x, y, z, xr, yr, zr, w) (Rotation is in quaternion form)
- sendLua(string lua_command)
