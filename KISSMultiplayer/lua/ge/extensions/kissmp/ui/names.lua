local M = {}

local overrideName = false
local text = ''

local function draw()
  for _, player in pairs(network.players) do
    local vehicle_id = vehiclemanager.id_map[player.current_vehicle] or -1
    local vehicle = be:getObjectByID(vehicle_id)
    local vehicle_position = vec3()
    if (not vehicle) or (kisstransform.inactive[vehicle_id]) then
      if kissplayers.players[player.current_vehicle] then
        vehicle_position = vec3(kissplayers.players[player.current_vehicle]:getPosition())
      elseif kisstransform.raw_transforms[player.current_vehicle] then
        vehicle_position = vec3(kisstransform.raw_transforms[player.current_vehicle].position)
      end
    else
      vehicle_position = vec3(vehicle:getPosition())
    end
      local local_position = getCameraPosition()
      local distance = vehicle_position:distance(vec3(local_position)) or 0
      vehicle_position.z = vehicle_position.z + 1.6

      if not M.overrideName then
        text = player.name.." ("..tostring(math.floor(distance)).."m)"
      else
        text = tostring(M.overrideName)
      end

      if text ~= '' then
        debugDrawer:drawTextAdvanced(
          Point3F(vehicle_position.x, vehicle_position.y, vehicle_position.z),
          String(text),
          ColorF(1, 1, 1, 1),
          true,
          false,
          ColorI(0, 0, 0, 255)
        )
      end
    end
end

M.overrideName = overrideName
M.draw = draw

return M