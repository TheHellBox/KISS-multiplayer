-- Cluster sync shared state — Phase 0 groundwork.
--
-- This module holds the per-vehicle cluster table, tuning constants,
-- and data structure stubs that future cluster-sync phases will fill
-- in. At Phase 0 it does nothing at runtime — it loads, exposes its
-- tables, and is ignored by the live sync path.
--
-- Future phases that build on this:
--   * cluster_discovery.lua (Phase 1) populates M.clusters at spawn
--   * cluster_topology.lua  (Phase 1) fills parent_link fields
--   * cluster_sender.lua    (Phase 2) reads M.clusters + M.const
--   * cluster_receiver.lua  (Phase 2) reads M.clusters + M.const
--   * rigidity_validator.lua(Phase 6) reads M.clusters to detect
--     drift and schedule re-cluster
--
-- See NodeClusterSync.md in the repo root for the full spec. This
-- file corresponds to §3.1 (data structures) and §8 (tuning
-- constants).
local M = {}

print("[KISS_CLUSTER] cluster_state.lua module body executing")

-- Tuning constants. Defaults from spec §8. These should be
-- overridable at runtime via kisstuning in later phases; for now
-- they're module-local and hard-coded.
M.const = {
  STIFFNESS_THRESHOLD             = 500000,  -- N/m, used by cluster_discovery
  MIN_CLUSTER_SIZE                = 8,       -- nodes, clusters smaller than this are merged/dropped
  KP_POS                          = 50.0,    -- position-error spring (1/s²) for velocity-matching PD-light term
  RIGIDITY_CHECK_INTERVAL_S       = 10.0,    -- periodic validator tick interval
  RIGIDITY_REVALIDATION_THRESHOLD_M = 0.05,  -- RMS per-node drift threshold that schedules re-cluster
  RECLUSTER_DEBOUNCE_S            = 1.0,     -- debounce window to coalesce beam-break storms
  SEND_RATE_HZ                    = 30,      -- per-vehicle cluster update rate
  MAX_FORCE_PER_NODE_N            = 50000,   -- paranoia clamp; log every hit
  -- Fraction of the velocity error closed per tick. 1.0 = stiff
  -- single-tick snap (fights local soft-body physics, elastic
  -- wobble). Lower = slower convergence but beams can respond
  -- naturally. Overridable at runtime via the tuning slider.
  CONVERGENCE_GAIN                = 0.3,
}

-- Per-vehicle cluster table. Populated at spawn by cluster_discovery.
-- Shape (per spec §3.1):
--   M.clusters[i] = {
--     id                 = i,
--     nodes              = {cid, cid, ...},
--     centroid_local     = vec3,  -- mass-weighted centroid in vehicle ref frame
--     node_offsets_local = { [cid] = vec3, ... },  -- per-node offsets in cluster local frame
--     total_mass         = number,
--     inertia_local      = mat3,  -- principal-axis tensor (cached)
--     is_root            = bool,  -- true iff contains the ref node
--     parent_id          = number | nil,  -- nil for root
--     parent_link = {             -- nil for root
--       type               = "coupler" | "hydro" | "slidenode",
--       anchor_node_local  = cid, -- on this cluster
--       anchor_node_parent = cid, -- on parent cluster
--     },
--     enabled            = bool,  -- per-cluster runtime kill-switch
--   }
M.clusters = {}

-- Stable hash of the current cluster topology. Computed by
-- cluster_discovery.lua after clusters are built. Recomputed on
-- any re-cluster event. See spec §4.4 for the hash function; the
-- implementation lives in cluster_topology.lua alongside the graph
-- construction code.
M.topology_hash = nil

-- Per-vehicle region table, built at spawn from JBeam `group` scope
-- modifiers on each node. Independent of clusters: a cluster can
-- span multiple regions, and a region can span multiple clusters.
-- Regions are the semantic partition BeamNG already uses for
-- flexbody mesh mapping (`body`, `door_r_st`, `engine_intake`, ...)
-- and are the reservation for Phase 10 per-region damage-sync LOD.
-- Shape:
--   M.regions[i] = { name = "body", nodes = {cid, cid, ...} }
-- Nodes with no `group` field land in a synthetic "(ungrouped)"
-- entry so they're still visualized.
M.regions = {}

-- Runtime state for the future per-cluster debug UI. Keyed by
-- cluster id. Not used at Phase 0; kept here so the UI module can
-- read/write without the sender/receiver modules needing to know
-- about debug toggles.
M.debug_state = {
  -- [cluster_id] = {
  --   log_enabled   = bool,  -- write per-tick CSV rows
  --   show_forces   = bool,  -- draw force arrows in 3D overlay
  --   force_fallback = bool, -- override: exclude this cluster from sync
  -- },
}

-- Called by later phases to reset state on vehicle reset or reload.
function M.clear()
  M.clusters = {}
  M.topology_hash = nil
  M.regions = {}
  M.debug_state = {}
end

return M
