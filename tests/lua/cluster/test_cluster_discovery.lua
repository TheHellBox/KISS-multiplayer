-- TDD tests for cluster_discovery. Written RED first; implementation
-- must pass these to be considered done.
--
-- Tests target the pure algorithmic core `discover_clusters()` which
-- takes simple explicit inputs (node list, beam list, boundary set,
-- ref node, constants) and returns clusters. The v.data adapter is
-- tested separately.

local T = {}

-- The module doesn't exist yet — tests fail with load error until
-- cluster_discovery.lua is written.
local discovery = require("cluster_discovery")

local DEFAULTS = {STIFFNESS_THRESHOLD = 500000, MIN_CLUSTER_SIZE = 8}
local STIFF = 1000000  -- above threshold
local WEAK = 100       -- below threshold

-- ============================================================
-- Helpers
-- ============================================================
local function set_of(...)
  local s = {}
  for i = 1, select("#", ...) do s[select(i, ...)] = true end
  return s
end

local function cluster_sizes(clusters)
  local sizes = {}
  for _, c in ipairs(clusters) do
    table.insert(sizes, #c.nodes)
  end
  table.sort(sizes)
  return sizes
end

local function cluster_has_node(cluster, cid)
  for _, n in ipairs(cluster.nodes) do
    if n == cid then return true end
  end
  return false
end

local function sizes_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- ============================================================
-- Basic single-body cases
-- ============================================================

function T.test_single_rigid_chain_forms_one_cluster()
  -- 10 nodes connected in a chain by stiff beams. No boundaries.
  local nodes = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
  local beams = {}
  for i = 1, 9 do
    table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF})
  end
  local clusters = discovery.discover_clusters(nodes, beams, {}, 1, DEFAULTS)
  assert(#clusters == 1, "expected 1 cluster, got " .. #clusters)
  assert(#clusters[1].nodes == 10,
    "expected 10 nodes in cluster, got " .. #clusters[1].nodes)
end

function T.test_single_cluster_contains_ref_node()
  local nodes = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
  local beams = {}
  for i = 1, 9 do
    table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF})
  end
  local clusters = discovery.discover_clusters(nodes, beams, {}, 5, DEFAULTS)
  assert(cluster_has_node(clusters[1], 5), "ref node should be in the cluster")
end

-- ============================================================
-- Stiffness threshold filtering
-- ============================================================

function T.test_weak_beams_filtered_out()
  -- Two rigid chains connected only by weak beams → two clusters.
  local nodes = {}
  for i = 1, 20 do table.insert(nodes, i) end
  local beams = {}
  -- Rigid chain A: 1-2-3-...-10
  for i = 1, 9 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  -- Rigid chain B: 11-12-...-20
  for i = 11, 19 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  -- Weak connection between the two chains
  table.insert(beams, {id1 = 10, id2 = 11, spring = WEAK})
  local clusters = discovery.discover_clusters(nodes, beams, {}, 1, DEFAULTS)
  assert(#clusters == 2, "expected 2 clusters, got " .. #clusters)
  assert(sizes_equal(cluster_sizes(clusters), {10, 10}),
    "expected two 10-node clusters")
end

function T.test_stiff_beam_above_exactly_threshold_counts()
  -- Beam exactly at the threshold is considered stiff
  local nodes = {}
  for i = 1, 10 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 9 do
    table.insert(beams, {id1 = i, id2 = i + 1, spring = DEFAULTS.STIFFNESS_THRESHOLD})
  end
  local clusters = discovery.discover_clusters(nodes, beams, {}, 1, DEFAULTS)
  assert(#clusters == 1, "at-threshold beams should be included")
  assert(#clusters[1].nodes == 10)
end

function T.test_stiff_beam_just_below_threshold_filtered()
  local nodes = {1, 2}
  local beams = {{id1 = 1, id2 = 2, spring = DEFAULTS.STIFFNESS_THRESHOLD - 1}}
  local clusters = discovery.discover_clusters(nodes, beams, {}, 1, DEFAULTS)
  -- Both nodes are isolated singletons after filtering → both below MIN_CLUSTER_SIZE
  -- → fallback to whole-vehicle cluster.
  assert(#clusters == 1, "fallback should produce 1 cluster")
  assert(#clusters[1].nodes == 2, "fallback should include all nodes")
end

-- ============================================================
-- Semantic boundary extraction (couplers / hydros / slidenodes)
-- ============================================================

function T.test_coupler_boundary_splits_into_two_clusters()
  -- 20 nodes in a single rigid chain, but node 10 and 11 are marked
  -- as boundary nodes (coupler endpoints between two logical halves).
  local nodes = {}
  for i = 1, 20 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 19 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  local boundary = set_of(10, 11)
  local clusters = discovery.discover_clusters(nodes, beams, boundary, 1, DEFAULTS)
  -- Beams touching boundary nodes (9-10, 10-11, 11-12) are removed
  -- from adj. Connected components: {1..9} (9 nodes, >= 8, passes)
  -- and {12..20} (9 nodes, passes). Boundary nodes 10, 11 are NOT in
  -- any cluster.
  assert(#clusters == 2, "expected 2 clusters across boundary, got " .. #clusters)
  assert(sizes_equal(cluster_sizes(clusters), {9, 9}),
    "expected two 9-node clusters")
end

function T.test_boundary_nodes_never_in_cluster()
  local nodes = {}
  for i = 1, 20 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 19 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  local boundary = set_of(10, 11)
  local clusters = discovery.discover_clusters(nodes, beams, boundary, 1, DEFAULTS)
  for _, c in ipairs(clusters) do
    assert(not cluster_has_node(c, 10), "boundary node 10 should not be in any cluster")
    assert(not cluster_has_node(c, 11), "boundary node 11 should not be in any cluster")
  end
end

-- ============================================================
-- Minimum cluster size filter
-- ============================================================

function T.test_small_cluster_dropped()
  -- Main rigid body of 10 nodes, plus a tiny 3-node fragment
  -- connected only by weak beams. The fragment is filtered out,
  -- the main body is returned.
  local nodes = {}
  for i = 1, 13 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 9 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end  -- 1..10
  for i = 11, 12 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end -- 11..13
  -- Only weak connection between them
  table.insert(beams, {id1 = 10, id2 = 11, spring = WEAK})
  local clusters = discovery.discover_clusters(nodes, beams, {}, 1, DEFAULTS)
  -- The 3-node fragment is below MIN_CLUSTER_SIZE=8, dropped.
  -- Only the 10-node chain survives.
  assert(#clusters == 1, "expected 1 cluster, got " .. #clusters)
  assert(#clusters[1].nodes == 10)
end

-- ============================================================
-- Fallback: no valid clusters OR ref not in any cluster
-- ============================================================

function T.test_no_valid_clusters_fallback_to_whole_vehicle()
  -- Too-small nodes, no beams → every node is isolated → fallback
  local nodes = {1, 2, 3}
  local beams = {}
  local clusters = discovery.discover_clusters(nodes, beams, {}, 1, DEFAULTS)
  assert(#clusters == 1, "fallback should produce 1 cluster")
  assert(#clusters[1].nodes == 3, "fallback should include all nodes")
end

function T.test_ref_node_in_boundary_falls_back()
  -- If the ref node happens to be a boundary node (weird edge case),
  -- ref node is not in any cluster → fallback to single whole-vehicle.
  local nodes = {}
  for i = 1, 20 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 19 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  local boundary = set_of(10)  -- ref node is a boundary
  local clusters = discovery.discover_clusters(nodes, beams, boundary, 10, DEFAULTS)
  assert(#clusters == 1, "fallback expected when ref is boundary, got " .. #clusters)
  -- Fallback cluster contains all nodes including the ref
  assert(#clusters[1].nodes == 20, "fallback should include all nodes")
  assert(cluster_has_node(clusters[1], 10), "fallback should include ref node")
end

function T.test_ref_node_not_in_any_cluster_falls_back()
  -- Ref node is real but its cluster is too small → fallback.
  local nodes = {}
  for i = 1, 13 do table.insert(nodes, i) end
  local beams = {}
  -- Big cluster A: 1..10
  for i = 1, 9 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  -- Tiny cluster B: 11..13 with ref node inside
  for i = 11, 12 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  -- Weak bridge
  table.insert(beams, {id1 = 10, id2 = 11, spring = WEAK})
  local clusters = discovery.discover_clusters(nodes, beams, {}, 12, DEFAULTS)
  -- The big cluster is valid (10 nodes), the small one would be
  -- filtered (3 nodes). Ref node 12 is in the filtered one → ref
  -- isn't in any valid cluster → fallback.
  assert(#clusters == 1, "expected fallback when ref is in filtered cluster")
  assert(#clusters[1].nodes == 13, "fallback includes all nodes")
end

-- ============================================================
-- Multiple valid clusters
-- ============================================================

function T.test_three_rigid_bodies_joined_by_couplers()
  -- Three rigid chains of 10 nodes each, connected via couplers at
  -- the shared nodes. Each body should be its own cluster (minus
  -- the coupler boundary nodes).
  local nodes = {}
  for i = 1, 30 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 9 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end   -- A
  for i = 11, 19 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end -- B
  for i = 21, 29 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end -- C
  -- Couplers at the gaps: node 10 couples to 11, node 20 couples to 21
  local boundary = set_of(10, 11, 20, 21)
  local clusters = discovery.discover_clusters(nodes, beams, boundary, 1, DEFAULTS)
  -- A: 1..9 (9 nodes), B: 12..19 (8 nodes), C: 22..30 (9 nodes)
  assert(#clusters == 3, "expected 3 clusters, got " .. #clusters)
  assert(sizes_equal(cluster_sizes(clusters), {8, 9, 9}),
    "expected sizes 8, 9, 9")
end

-- ============================================================
-- Determinism
-- ============================================================

function T.test_determinism_across_runs()
  -- Same input → identical output. Cluster ordering must be stable.
  local nodes = {}
  for i = 1, 20 do table.insert(nodes, i) end
  local beams = {}
  for i = 1, 9 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  for i = 11, 19 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  local boundary = set_of(10)

  local run1 = discovery.discover_clusters(nodes, beams, boundary, 1, DEFAULTS)
  local run2 = discovery.discover_clusters(nodes, beams, boundary, 1, DEFAULTS)

  assert(#run1 == #run2, "cluster counts differ between runs")
  for i = 1, #run1 do
    assert(#run1[i].nodes == #run2[i].nodes,
      string.format("cluster %d size differs: %d vs %d",
        i, #run1[i].nodes, #run2[i].nodes))
    for j = 1, #run1[i].nodes do
      assert(run1[i].nodes[j] == run2[i].nodes[j],
        string.format("cluster %d node %d differs: %s vs %s",
          i, j, tostring(run1[i].nodes[j]), tostring(run2[i].nodes[j])))
    end
  end
end

function T.test_determinism_under_input_shuffle()
  -- Shuffling the input beams/nodes should not change the cluster
  -- partition (node sets should match regardless of input order).
  local nodes_a = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
  local nodes_b = {10, 9, 8, 7, 6, 5, 4, 3, 2, 1}
  local beams = {}
  for i = 1, 9 do table.insert(beams, {id1 = i, id2 = i + 1, spring = STIFF}) end
  local beams_shuffled = {}
  for i = #beams, 1, -1 do table.insert(beams_shuffled, beams[i]) end

  local c1 = discovery.discover_clusters(nodes_a, beams, {}, 1, DEFAULTS)
  local c2 = discovery.discover_clusters(nodes_b, beams_shuffled, {}, 1, DEFAULTS)

  assert(#c1 == #c2, "cluster counts differ under shuffle")
  assert(#c1[1].nodes == #c2[1].nodes, "cluster sizes differ under shuffle")
end

return T
