local M = {}

-- Spectate fix: block local joystick/keyboard input from leaking into
-- non-owned vehicles. When two BeamNG instances on the same machine
-- receive the same controller input simultaneously (e.g. the dev's own
-- A/B test rig), the "remote viewer" instance would apply the local
-- joystick input to the non-owned vehicle, racing against the network
-- sync packets. The remote vehicle then fluctuates between the local
-- joystick value and the synced value — causing spurious drift that
-- the PD loop then fights.
--
-- Implementation: monkey-patch input.event to no-op on non-owned
-- vehicles, but set a guard flag around our own sync calls so the
-- mod's apply() still reaches the underlying function.
local is_owned = true  -- assume owned until kissUpdateOwnership says otherwise
local sync_in_progress = false
local real_input_event = nil
local real_input_kbdSteer = nil
local real_input_kbdPedal = nil
local patched = false

local function input_event_patched(...)
  if (not is_owned) and (not sync_in_progress) then
    return  -- block local input on spectated vehicles
  end
  return real_input_event(...)
end

local function install_patch()
  if patched then return end
  if type(input) ~= "table" or type(input.event) ~= "function" then return end
  real_input_event = input.event
  input.event = input_event_patched
  -- Also wrap the keyboard-specific input entry points if present,
  -- since they can bypass input.event on some builds.
  if type(input.kbdSteer) == "function" then
    real_input_kbdSteer = input.kbdSteer
    input.kbdSteer = function(...)
      if (not is_owned) and (not sync_in_progress) then return end
      return real_input_kbdSteer(...)
    end
  end
  if type(input.kbdPedal) == "function" then
    real_input_kbdPedal = input.kbdPedal
    input.kbdPedal = function(...)
      if (not is_owned) and (not sync_in_progress) then return end
      return real_input_kbdPedal(...)
    end
  end
  patched = true
end

local function apply(data)
  install_patch()
  local data = jsonDecode(data)
  sync_in_progress = true
  input.event("throttle", data.throttle_input, 1)
  input.event("brake", data.brake_input, 2)
  input.event("parkingbrake", data.parkingbrake, 2)
  input.event("clutch", data.clutch, 1)
  input.event("steering", data.steering_input, 2, 0, 0)
  sync_in_progress = false
end

local function kissUpdateOwnership(owned)
  is_owned = owned and true or false
  install_patch()
  if owned then
    -- Owned again: re-enable FFB (in case we're switching back)
    return
  end
  hydros.enableFFB = false
  hydros.onFFBConfigChanged(nil)
end

M.apply = apply

M.kissUpdateOwnership = kissUpdateOwnership

return M
