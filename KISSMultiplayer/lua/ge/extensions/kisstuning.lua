-- Local tuning state for coupled-rig heading correction.
-- Held here on the GE side and pushed to each tick's
-- kiss_transforms.update() call on the vehicle side. Local-only: each
-- player tunes their own rendering of other players' trucks. No network
-- sync — clients can share values out of band if desired.
local M = {}

-- Current tuning values (defaults). Every slider in the UI maps to one
-- entry here; every coupled-truck physics tick reads from these.
M.values = {
  Kp_yaw                      = 1.0,
  Kd_yaw                      = 0.35,
  force_cap_accel             = 0.6,
  speed_gate_low              = 1.5,
  speed_gate_high             = 5.5,
  accel_clamp                 = 15.0,
  lateral_pd_scale            = 0.2,
  lateral_integral_gain       = 0.5,
  sample_rate_multiplier      = 1.0,
  prediction_enabled          = true,
  deadband_enabled            = false,
  use_front_puller_solo       = true,
  -- Cluster-sync scaffolding. Plumbed through update() but not read
  -- on the vehicle side until Phase 2. Currently defaults ON for
  -- testing so the Phase 1 debug overlay (colored AABBs around each
  -- discovered cluster) is visible by default on every vehicle.
  -- Until Phase 2 actually wires the sender/receiver, this flag
  -- does nothing force-related — legacy PD path still handles sync.
  cluster_sync_enabled        = true,
  cluster_sync_force_fallback = false,
  cluster_convergence_gain    = 0.3,
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
    key = "sample_rate_multiplier",
    label = "Outgoing packet rate ×",
    min = 0.5, max = 4.0, default = 1.0,
    desc = "Multiplies this client's own vehicle-update send rate. Only affects how often YOUR owned vehicles broadcast state to others — not how often you receive. Higher = smoother remote view of your vehicles at higher upload bandwidth cost. Lower = less bandwidth, more visible latency for your vehicles on other clients.",
  },
  {
    key = "prediction_enabled",
    type = "bool",
    label = "Position/rotation prediction",
    default = true,
    desc = "On: extrapolate received transform forward by latency (kinematic position, axis-angle rotation). Off: use received transform directly as target — no extrapolation. Turn off to A/B test whether prediction is adding value or adding error on the current tuning; remote will appear latency-delayed but without extrapolation artifacts.",
  },
  {
    key = "deadband_enabled",
    type = "bool",
    label = "Near-target deadband",
    default = false,
    desc = "On: skip PD corrections below 15cm position error (prevents cargo on tilt decks from jiggling at rest, but leaves up to 15cm of visible position offset at rest). Off: PD always runs to zero position error (exact parking but micro-jitter on stationary loose cargo).",
  },
  {
    key = "use_front_puller_solo",
    type = "bool",
    label = "Front-puller for solo vehicles",
    default = true,
    desc = "Apply the lateral-force-at-front-chassis mechanism to solo non-coupled vehicles. On = same mechanism as coupled trucks, which models front-steered cars more naturally. Off = legacy angular PD (rigid-body torque around CG) — only useful for diagnosing whether front-puller is causing some regression.",
  },
  {
    key = "cluster_sync_enabled",
    type = "bool",
    label = "Cluster sync (EXPERIMENTAL)",
    default = true,
    desc = "Default ON for testing. Currently does nothing at runtime (Phase 1 only does cluster discovery + debug overlay, which run regardless of this toggle). When future phases wire the sender/receiver, this flag will gate whether a vehicle is synced via per-cluster velocity matching (ON) or via the legacy front-puller/PID path (OFF).",
  },
  {
    key = "cluster_convergence_gain",
    label = "Cluster sync convergence gain",
    min = 0.05, max = 1.0, default = 0.3,
    desc = "Fraction of per-node velocity error closed per tick in the cluster-sync force path. 1.0 = fully closed in one tick (stiffest, may produce elastic wobble as sync forces fight local beam physics); 0.05 = very soft, takes ~20 ticks to converge but lets the soft-body solver breathe. Try 0.2-0.4 as a starting range. No effect when cluster sync is disabled.",
  },
  {
    key = "cluster_sync_force_fallback",
    type = "bool",
    label = "Force cluster fallback",
    default = false,
    desc = "Diagnostic override: when on, any vehicle that would use cluster sync falls back to the legacy front-puller/PID path regardless of topology. Lets you A/B compare cluster vs legacy in the same session when cluster sync is implemented. No effect at Phase 0.",
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
