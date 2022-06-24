local M = {}
M.el = vec3(0.08, 0, 0)
M.er = vec3(-0.08, 0, 0)

local function onUpdate()
  if not network.connection.connected then return end
  local position = vec3(getCameraPosition() or vec3())
  local ear_left = M.el:rotated(quat(getCameraQuat()))
  local ear_right = M.er:rotated(quat(getCameraQuat()))
  local pl = position + ear_left
  local pr = position + ear_right
  --debugDrawer:drawSphere((pl + vec3(0, 2, 0):rotated(quat(getCameraQuat()))):toPoint3F(), 0.05, ColorF(0,1,0,0.8))
  --debugDrawer:drawSphere((pr + vec3(0, 2, 0):rotated(quat(getCameraQuat()))):toPoint3F(), 0.05, ColorF(0,0,1,0.8))
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
