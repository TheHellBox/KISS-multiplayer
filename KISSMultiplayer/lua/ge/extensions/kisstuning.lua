-- Local tuning state for coupled-rig heading correction.
-- Held here on the GE side and pushed to each tick's
-- kiss_transforms.update() call on the vehicle side. Local-only: each
-- player tunes their own rendering of other players' trucks. No network
-- sync — clients can share values out of band if desired.
local M = {}

-- Current tuning values (defaults). Every slider in the UI maps to one
-- entry here; every coupled-truck physics tick reads from these.
M.values = {
  Kp_yaw                 = 1.0,
  Kd_yaw                 = 0.35,
  force_cap_accel        = 0.6,
  speed_gate_low         = 1.5,
  speed_gate_high        = 5.5,
  accel_clamp            = 15.0,
  lateral_pd_scale       = 0.2,
  lateral_integral_gain  = 0.5,
  deadband_enabled       = true,
  use_front_puller_solo  = false,
}

-- UI metadata: label, range, default, one-sentence description including
-- what the extremes do. Rendered by kissmp/ui/tabs/tuning.lua.
--
-- Spec entries may include a `type` field: "float" (default, slider) or
-- "bool" (checkbox). Float specs require min/max; bool specs use
-- `default = true|false`.
M.specs = {
  {
    key = "Kp_yaw",
    label = "Yaw correction strength",
    min = 0.0, max = 3.0, default = 1.0,
    desc = "How hard remote rigs correct heading: too low and trailers drift / drag; too high and the rig oscillates or overcorrects into the turn.",
  },
  {
    key = "Kd_yaw",
    label = "Yaw damping",
    min = 0.0, max = 1.0, default = 0.35,
    desc = "Opposes yaw rate: too low and the correction rings back and forth; too high and the rig feels sluggish and fights driver steering.",
  },
  {
    key = "force_cap_accel",
    label = "Max correction accel (m/s²)",
    min = 0.05, max = 5.0, default = 0.6,
    desc = "Upper limit on chassis-level lateral acceleration from sync: too low and large heading errors can't close; too high and trailers get yanked / cargo slides off.",
  },
  {
    key = "speed_gate_low",
    label = "Low-speed gate (m/s)",
    min = 0.1, max = 5.0, default = 1.5,
    desc = "Speed below which the front-puller goes to zero: too low and tire dynamics can't cleanly convert lateral force into yaw (slide/wobble at walking pace); too high and heading correction cuts off too early during deceleration, leaving residual yaw error frozen at rest.",
  },
  {
    key = "speed_gate_high",
    label = "High-speed gate (m/s)",
    min = 2.0, max = 15.0, default = 5.5,
    desc = "Speed at which the lateral-force path reaches full strength: too low and the old angular-torque whip returns during slow driving; too high and heading drifts during cruising.",
  },
  {
    key = "accel_clamp",
    label = "Max predicted accel (m/s²)",
    min = 1.0, max = 30.0, default = 15.0,
    desc = "Upper limit on received acceleration used for position prediction: too low and cornering/braking extrapolation under-predicts the curve (target sphere sweeps across vehicle during turns); too high and crash/impact transients cause the target to jump wildly.",
  },
  {
    key = "lateral_pd_scale",
    label = "Lateral PD strength (mid-turn floor)",
    min = 0.0, max = 1.0, default = 0.2,
    desc = "Soft floor for the lateral PD during active turns (auto-balance interpolates between this and 1.0 based on current yaw rate): too low and the rig trails sideways during hard corners; too high and the PD drags the chassis inward fighting the tires. Straight-line driving always uses full strength (1.0) regardless of this value.",
  },
  {
    key = "lateral_integral_gain",
    label = "Lateral self-centering (Ki)",
    min = 0.0, max = 3.0, default = 0.5,
    desc = "Integral gain for the lateral axis: accumulates residual drift over time and pushes back toward centerline. Too low and steady-state drift never closes; too high and the integral winds up during turns, producing oscillating self-centering kicks.",
  },
  {
    key = "deadband_enabled",
    type = "bool",
    label = "Near-target deadband",
    default = true,
    desc = "On: skip PD corrections below 15cm position error (prevents cargo on tilt decks from jiggling at rest, but leaves up to 15cm of visible position offset at rest). Off: PD always runs to zero position error (exact parking but micro-jitter on stationary loose cargo).",
  },
  {
    key = "use_front_puller_solo",
    type = "bool",
    label = "Front-puller for solo vehicles",
    default = false,
    desc = "Experimental: apply the lateral-force-at-front-chassis mechanism to solo non-coupled vehicles. Off = legacy angular PD (rigid-body torque around CG). On = same mechanism as coupled trucks, which models front-steered cars more naturally but is less battle-tested for solo use.",
  },
}

function M.get(key)
  return M.values[key]
end

function M.set(key, value)
  if M.values[key] == nil then return end
  M.values[key] = value
end

-- Reset all values to their spec defaults. Used by the "Reset" button.
function M.reset_defaults()
  for _, spec in ipairs(M.specs) do
    M.values[spec.key] = spec.default
  end
end

return M
