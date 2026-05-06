local M = {}

local camera_pos = vec3()
local nametag_position = vec3()
local vehicle_center = vec3()
local vehicle_offset = vec3()

local text_color = ColorF(1, 1, 1, 1)
local background_color = ColorI(0, 0, 0, 255)

local colorful_names = false
local fade_names = true
local fade_names_start_distance = 100
local use_z_names = true

local function draw()
  camera_pos:set(core_camera.getPositionXYZ())
  for id, player in pairs(kissmp_players.players) do
    if id ~= kissmp_network.connection.client_id and player.current_vehicle then
      local vehicle_id = kissmp_vehiclemanager.id_map[player.current_vehicle] or -1
      local vehicle = getObjectByID(vehicle_id)
      local distance = 0

      local raw_pos = kissmp_transform.raw_positions[player.current_vehicle]
      if vehicle and vehicle:getActive() then
        vehicle_center:set(be:getObjectOOBBCenterXYZ(vehicle_id))
        vehicle_offset:set(be:getObjectOOBBHalfAxisXYZ(vehicle_id, 2))

        nametag_position:setAdd2(vehicle_center, vehicle_offset)
        distance = vehicle_center:distance(camera_pos)
      elseif raw_pos then
        nametag_position:set(raw_pos[1], raw_pos[2], raw_pos[3])
        distance = nametag_position:distance(camera_pos)
        nametag_position.z = nametag_position.z + 1.6
      end

      if colorful_names then
        local r,g,b,_ = kissmp_players.get_player_color(id)
        text_color.r = r
        text_color.g = g
        text_color.b = b
      end

      if fade_names then
        local factor = linearScale(distance, fade_names_start_distance, fade_names_start_distance + 100, 1, 0)
        text_color.a = factor
        background_color.a = 255 * factor
      end

      if text_color.a > 0 then
        debugDrawer:drawTextAdvanced(
          nametag_position,
          string.format(" %s (%dm) ", player.name, math.floor(distance)),
          text_color,
          true,
          false,
          background_color,
          false,
          use_z_names
        )
      end
    end
  end
end

local function onKissMPSettingsChanged(config)
  fade_names = config["players.nametags.fade"]
  fade_names_start_distance = config["players.nametags.fade_start_distance"]
  colorful_names = config["players.nametags.colorful"]
  use_z_names = config["players.nametags.use_z"]

  if not fade_names then
    text_color.a = 1
    background_color.a = 255
  end

  if not colorful_names then
    text_color.r = 1
    text_color.g = 1
    text_color.b = 1
  end
end

M.draw = draw
M.onKissMPSettingsChanged = onKissMPSettingsChanged

return M
