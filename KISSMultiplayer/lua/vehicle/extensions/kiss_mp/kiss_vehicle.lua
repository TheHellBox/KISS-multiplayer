local M = {}

local generation = 0

-- Wtf I need to do this. BeamNG devs, that's crap!
local function update_rotation()
  local r = obj:getRotation()
  obj:queueGameEngineLua("vehiclemanager.push_rotation("..obj:getID()..", "..r.x..", "..r.y..", "..r.z..", "..r.w..")")
end

M.update_rotation = update_rotation

return M
