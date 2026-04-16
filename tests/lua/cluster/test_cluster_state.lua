-- Phase 0 smoke test: cluster_state module loads and exposes the
-- expected shape. This is not a TDD test — it's a regression check
-- that the scaffolding doesn't break on future edits.
--
-- Real TDD tests for the math come in Phase 1 (cluster discovery,
-- topology hash) and Phase 2 (Kabsch/Horn rotation fit).

local T = {}

-- The module under test is pure Lua with no BeamNG dependencies at
-- Phase 0, so we can require it directly.
local cluster_state = require("cluster_state")

function T.test_module_loads()
  assert(type(cluster_state) == "table", "cluster_state should return a table")
end

function T.test_const_table_present()
  assert(type(cluster_state.const) == "table", "M.const should be a table")
end

function T.test_const_defaults_from_spec_section_8()
  -- Values from NodeClusterSync.md §8. If these change, the spec
  -- and this test should be updated together.
  local c = cluster_state.const
  assert(c.STIFFNESS_THRESHOLD == 500000, "STIFFNESS_THRESHOLD")
  assert(c.MIN_CLUSTER_SIZE == 8, "MIN_CLUSTER_SIZE")
  assert(c.KP_POS == 50.0, "KP_POS")
  assert(c.RIGIDITY_CHECK_INTERVAL_S == 10.0, "RIGIDITY_CHECK_INTERVAL_S")
  assert(c.RIGIDITY_REVALIDATION_THRESHOLD_M == 0.05, "RIGIDITY_REVALIDATION_THRESHOLD_M")
  assert(c.RECLUSTER_DEBOUNCE_S == 1.0, "RECLUSTER_DEBOUNCE_S")
  assert(c.SEND_RATE_HZ == 30, "SEND_RATE_HZ")
  assert(c.MAX_FORCE_PER_NODE_N == 50000, "MAX_FORCE_PER_NODE_N")
end

function T.test_clusters_table_empty_on_load()
  assert(type(cluster_state.clusters) == "table", "M.clusters should be a table")
  -- A freshly-loaded module has no clusters until cluster_discovery
  -- runs at spawn.
  local count = 0
  for _ in pairs(cluster_state.clusters) do count = count + 1 end
  assert(count == 0, "M.clusters should be empty at load time, got " .. count)
end

function T.test_topology_hash_nil_on_load()
  assert(cluster_state.topology_hash == nil,
    "topology_hash should be nil until cluster_discovery runs")
end

function T.test_debug_state_table_present()
  assert(type(cluster_state.debug_state) == "table", "M.debug_state should be a table")
end

function T.test_clear_function_resets_state()
  -- Populate state, then clear() should reset
  cluster_state.clusters[1] = {id = 1, nodes = {1, 2, 3}}
  cluster_state.topology_hash = "fake_hash"
  cluster_state.debug_state[1] = {log_enabled = true}

  cluster_state.clear()

  assert(next(cluster_state.clusters) == nil, "clusters should be empty after clear")
  assert(cluster_state.topology_hash == nil, "topology_hash should be nil after clear")
  assert(next(cluster_state.debug_state) == nil, "debug_state should be empty after clear")
end

return T
