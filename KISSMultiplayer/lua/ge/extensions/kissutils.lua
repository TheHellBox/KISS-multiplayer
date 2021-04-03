local M = {}

M.hooks = {
  internal = {}
}

M.hooks.clear = function()
  M.hooks.internal = {}
end

M.hooks.register = function(hook_name, subname, fn)
  if not M.hooks.internal[hook_name] then M.hooks.internal[hook_name] = {} end
  M.hooks.internal[hook_name][sub_name] = fn
end

M.hooks.call = function(hook_name, ...)
  for k, v in pairs(M.hooks.internal[hook_name]) do
    v(arg)
  end
end

local function onUpdate(dt)
  M.hooks.call("onUpdate", dt)
end

--M.onUpdate = onUpdate

return M
