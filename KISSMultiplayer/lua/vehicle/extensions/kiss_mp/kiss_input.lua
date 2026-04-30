local M = {}

local ownership = true
local local_inputs_disabled = false
local remote_input_source = "KissMP"
local controlled_inputs = {
  throttle = true,
  brake = true,
  parkingbrake = true,
  clutch = true,
  steering = true,
}

local function set_local_input_allowed(allowed)
  if not input or not input.setAllowedInputSource then return end
  for input_name in pairs(controlled_inputs) do
    input.setAllowedInputSource(input_name, "local", allowed)
    input.setAllowedInputSource(input_name, remote_input_source, not allowed)
  end
  local_inputs_disabled = not allowed
end

local function apply(data)
  if ownership then return end
  local data = jsonDecode(data)
  input.event("throttle", data.throttle_input, 1, nil, nil, nil, remote_input_source)
  input.event("brake", data.brake_input, 2, nil, nil, nil, remote_input_source)
  input.event("parkingbrake", data.parkingbrake, 2, nil, nil, nil, remote_input_source)
  input.event("clutch", data.clutch, 1, nil, nil, nil, remote_input_source)
  input.event("steering", data.steering_input, 2, 0, 0, nil, remote_input_source)
end

local function kissUpdateOwnership(owned)
  ownership = owned and true or false
  if ownership then
    if local_inputs_disabled then
      set_local_input_allowed(true)
    end
    return
  end

  set_local_input_allowed(false)
  if hydros then
    hydros.enableFFB = false
    hydros.onFFBConfigChanged(nil)
  end
end

local function updateGFX()
  if not ownership and not local_inputs_disabled then
    set_local_input_allowed(false)
  end
end

M.apply = apply
M.updateGFX = updateGFX

M.kissUpdateOwnership = kissUpdateOwnership

return M
