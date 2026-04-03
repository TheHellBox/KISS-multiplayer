local M = {}

local camera_pos = vec3()
local vehicle_position = vec3()

local text_color = ColorF(1, 1, 1, 1)
local background_color = ColorI(0, 0, 0, 255)

local function draw()
  camera_pos:set(core_camera.getPositionXYZ())
  for id, player in pairs(network.players) do
    if id ~= network.connection.client_id and player.current_vehicle then
      local vehicle_id = vehiclemanager.id_map[player.current_vehicle] or -1
      local vehicle = getObjectByID(vehicle_id)
      if not vehicle or kisstransform.inactive[vehicle_id] then
        if kissplayers.players[player.current_vehicle] then
          vehicle_position:set(kissplayers.players[player.current_vehicle]:getPositionXYZ())
        elseif kisstransform.raw_transforms[player.current_vehicle] then
          local position = kisstransform.raw_transforms[player.current_vehicle].position
          vehicle_position:set(position[1], position[2], position[3])
        end
      else
        vehicle_position:set(vehicle:getPositionXYZ())
      end

      local distance = vehicle_position:distance(camera_pos) or 0
      vehicle_position.z = vehicle_position.z + 1.6
      debugDrawer:drawTextAdvanced(
        vehicle_position,
        player.name.." ("..tostring(math.floor(distance)).."m)",
        text_color,
        true,
        false,
        background_color,
        false,
        false
      )
    end
  end
end

M.draw = draw

return M
