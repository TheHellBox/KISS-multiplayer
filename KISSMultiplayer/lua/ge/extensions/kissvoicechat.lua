local M = {}
M.el = vec3(0.08, 0, 0)
M.er = vec3(-0.08, 0, 0)

local position = vec3()
local pl, pr = vec3(), vec3()
local cam_rot = quat()

local function onUpdate()
  if not network.connection.connected then return end
  position:set(core_camera.getPositionXYZ())
  cam_rot:set(core_camera.getQuatXYZW())

  pl:set(M.el)
  pl:setRotate(cam_rot)
  pl:setAdd(position)

  pr:set(M.er)
  pr:setRotate(cam_rot)
  pr:setAdd(position)

  --debugDrawer:drawSphere((pl + vec3(0, 2, 0):rotated(quat(getCameraQuat()))), 0.05, ColorF(0,1,0,0.8))
  --debugDrawer:drawSphere((pr + vec3(0, 2, 0):rotated(quat(getCameraQuat()))), 0.05, ColorF(0,0,1,0.8))
  network.send_data({
      SpatialUpdate = {{pl.x, pl.y, pl.z}, {pr.x, pr.y, pr.z}}
  })
end

local function start_vc()
  network.send_data('"StartTalking"')
end


local function end_vc()
  network.send_data('"EndTalking"')
end

M.onUpdate = onUpdate
M.start_vc = start_vc
M.end_vc = end_vc

return M
