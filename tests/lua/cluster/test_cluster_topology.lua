-- TDD tests for cluster_topology: parent-child graph construction
-- and topology hash computation. Per spec §4.2 and §4.4.
--
-- Red first. Implementation must pass these to be considered done.

local T = {}

local topology = require("cluster_topology")

-- ============================================================
-- Helpers
-- ============================================================
local function cluster_with_nodes(...)
  local nodes = {}
  for i = 1, select("#", ...) do nodes[i] = select(i, ...) end
  return {nodes = nodes}
end

local function cluster_ids_in_order(assigned)
  local ids = {}
  for _, c in ipairs(assigned) do table.insert(ids, c.id) end
  return ids
end

-- ============================================================
-- Parent-child graph construction (spec §4.2)
-- ============================================================
-- Input to build_topology():
--   clusters:    list of {nodes=...} as produced by cluster_discovery
--   links:       list of {type, node_a, node_b} — each link spans
--                two nodes, each of which may or may not be in a
--                cluster. (These represent couplers, hydros,
--                slidenodes — the semantic boundaries.)
--   ref_node:    ref node cid
--
-- Output: the same clusters list with added fields:
--   c.id          (1-based index, assigned by traversal order)
--   c.is_root     true iff contains ref node
--   c.parent_id   nil for root, else parent cluster id
--   c.parent_link nil for root, else {type, anchor_node_local,
--                 anchor_node_parent}

function T.test_single_cluster_becomes_root()
  local clusters = {cluster_with_nodes(1, 2, 3, 4, 5)}
  topology.build_topology(clusters, {}, 3)
  assert(clusters[1].id == 1)
  assert(clusters[1].is_root == true)
  assert(clusters[1].parent_id == nil)
  assert(clusters[1].parent_link == nil)
end

function T.test_two_clusters_one_coupler_root_contains_ref()
  -- Cluster A has ref; cluster B is linked to A via a coupler.
  -- Expected: A is root, B is child of A.
  local clusters = {
    cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),
    cluster_with_nodes(12, 13, 14, 15, 16, 17, 18, 19, 20),
  }
  -- Coupler spans node 10 (conceptually adjacent to cluster A via
  -- dropped boundary) and node 11 (adjacent to cluster B).
  -- Topology link: its two endpoints are each "nearest" to one of
  -- the clusters. For the test we provide the nearest cluster ids
  -- directly to avoid re-implementing nearest-cluster search here.
  local links = {
    {
      type = "coupler",
      cluster_a = 1, anchor_a = 9,   -- nearest node in cluster A
      cluster_b = 2, anchor_b = 12,  -- nearest node in cluster B
    },
  }
  topology.build_topology(clusters, links, 3)  -- ref in cluster A

  -- Cluster with the ref becomes root
  local root, child
  for _, c in ipairs(clusters) do
    if c.is_root then root = c else child = c end
  end
  assert(root ~= nil, "expected a root cluster")
  assert(child ~= nil, "expected a child cluster")
  assert(root.parent_id == nil)
  assert(child.parent_id == root.id, "child should point to root")
  assert(child.parent_link ~= nil, "child should have a parent_link")
  assert(child.parent_link.type == "coupler")
  assert(child.parent_link.anchor_node_local == 12)
  assert(child.parent_link.anchor_node_parent == 9)
end

function T.test_ref_in_second_cluster_still_roots_it()
  -- Same setup as previous but ref is in cluster B.
  local clusters = {
    cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),
    cluster_with_nodes(12, 13, 14, 15, 16, 17, 18, 19, 20),
  }
  local links = {
    {
      type = "coupler",
      cluster_a = 1, anchor_a = 9,
      cluster_b = 2, anchor_b = 12,
    },
  }
  topology.build_topology(clusters, links, 15)  -- ref in cluster B

  -- The cluster containing the ref (the second one) should be root.
  -- The OTHER cluster becomes its child.
  local root, child
  for _, c in ipairs(clusters) do
    if c.is_root then root = c else child = c end
  end
  assert(root.nodes[1] == 12, "root should be cluster B (starts with 12)")
  assert(child.nodes[1] == 1, "child should be cluster A")
  assert(child.parent_id == root.id)
  -- Parent link direction flipped
  assert(child.parent_link.anchor_node_local == 9)
  assert(child.parent_link.anchor_node_parent == 12)
end

function T.test_three_clusters_chain()
  -- A - B - C linked by couplers. Ref in A. Expected chain:
  -- A is root, B is child of A, C is child of B.
  local clusters = {
    cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),       -- A
    cluster_with_nodes(12, 13, 14, 15, 16, 17, 18, 19),  -- B
    cluster_with_nodes(22, 23, 24, 25, 26, 27, 28, 29),  -- C
  }
  local links = {
    {type = "coupler", cluster_a = 1, anchor_a = 9,  cluster_b = 2, anchor_b = 12},
    {type = "coupler", cluster_a = 2, anchor_a = 19, cluster_b = 3, anchor_b = 22},
  }
  topology.build_topology(clusters, links, 3)  -- ref in A

  -- Sanity: ids are assigned
  for _, c in ipairs(clusters) do
    assert(c.id ~= nil)
  end
  -- Identify by their first-node cid
  local by_first = {}
  for _, c in ipairs(clusters) do by_first[c.nodes[1]] = c end

  local a = by_first[1]
  local b = by_first[12]
  local c = by_first[22]

  assert(a.is_root == true, "A should be root (contains ref 3)")
  assert(b.parent_id == a.id, "B parent should be A")
  assert(c.parent_id == b.id, "C parent should be B")
end

function T.test_disconnected_cluster_becomes_its_own_root()
  -- Two clusters, NO link between them. Both are root candidates.
  -- The one containing the ref is root in the normal sense;
  -- the other one has no path to the ref cluster → it becomes its
  -- own root (is_root=true, parent_id=nil). Log-worthy in real
  -- code but not an error.
  local clusters = {
    cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),
    cluster_with_nodes(11, 12, 13, 14, 15, 16, 17, 18, 19),
  }
  topology.build_topology(clusters, {}, 3)

  local ref_cluster, orphan
  for _, c in ipairs(clusters) do
    local has_ref = false
    for _, n in ipairs(c.nodes) do if n == 3 then has_ref = true end end
    if has_ref then ref_cluster = c else orphan = c end
  end

  assert(ref_cluster.is_root == true, "ref cluster is root")
  assert(orphan.is_root == true, "orphan also becomes its own root")
  assert(orphan.parent_id == nil)
  assert(orphan.parent_link == nil)
end

function T.test_ids_are_stable_across_calls()
  -- Same input, two calls → same assigned ids.
  local function mk()
    return {
      cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),
      cluster_with_nodes(12, 13, 14, 15, 16, 17, 18, 19),
    }
  end
  local links = {
    {type = "coupler", cluster_a = 1, anchor_a = 9, cluster_b = 2, anchor_b = 12},
  }
  local c1 = mk(); topology.build_topology(c1, links, 3)
  local c2 = mk(); topology.build_topology(c2, links, 3)
  assert(c1[1].id == c2[1].id)
  assert(c1[2].id == c2[2].id)
end

-- ============================================================
-- Topology hash (spec §4.4)
-- ============================================================

function T.test_hash_is_string()
  local clusters = {cluster_with_nodes(1, 2, 3, 4, 5)}
  topology.build_topology(clusters, {}, 3)
  local h = topology.compute_hash(clusters)
  assert(type(h) == "string", "hash should be a string, got " .. type(h))
  assert(#h > 0, "hash should be non-empty")
end

function T.test_hash_is_stable_across_runs()
  local function mk()
    local cs = {
      cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),
      cluster_with_nodes(12, 13, 14, 15, 16, 17, 18, 19),
    }
    local links = {{type = "coupler", cluster_a = 1, anchor_a = 9, cluster_b = 2, anchor_b = 12}}
    topology.build_topology(cs, links, 3)
    return cs
  end
  local h1 = topology.compute_hash(mk())
  local h2 = topology.compute_hash(mk())
  assert(h1 == h2, "hash should be stable: " .. h1 .. " vs " .. h2)
end

function T.test_hash_insensitive_to_node_order_within_cluster()
  -- Same partition but nodes within cluster listed in different
  -- order should yield the same hash (sort internally).
  local clusters1 = {cluster_with_nodes(1, 2, 3, 4, 5)}
  local clusters2 = {cluster_with_nodes(5, 4, 3, 2, 1)}
  topology.build_topology(clusters1, {}, 3)
  topology.build_topology(clusters2, {}, 3)
  assert(topology.compute_hash(clusters1) == topology.compute_hash(clusters2),
    "hash should be order-insensitive within a cluster")
end

function T.test_hash_sensitive_to_cluster_count()
  local c1 = {cluster_with_nodes(1, 2, 3, 4, 5)}
  topology.build_topology(c1, {}, 3)
  local c2 = {
    cluster_with_nodes(1, 2, 3),
    cluster_with_nodes(4, 5),
  }
  topology.build_topology(c2, {}, 2)
  assert(topology.compute_hash(c1) ~= topology.compute_hash(c2),
    "hash should differ when the partition differs")
end

function T.test_hash_sensitive_to_cluster_membership()
  -- Two clusters, different membership → different hash.
  local c1 = {
    cluster_with_nodes(1, 2, 3),
    cluster_with_nodes(4, 5, 6),
  }
  topology.build_topology(c1, {}, 2)
  local c2 = {
    cluster_with_nodes(1, 2, 4),  -- different membership
    cluster_with_nodes(3, 5, 6),
  }
  topology.build_topology(c2, {}, 2)
  assert(topology.compute_hash(c1) ~= topology.compute_hash(c2),
    "hash should differ when cluster membership differs")
end

function T.test_hash_sensitive_to_parent_structure()
  -- Same node partition but different parent-child relationships.
  -- (If we change which cluster is root, the structure differs.)
  local function mk(ref)
    local cs = {
      cluster_with_nodes(1, 2, 3, 4, 5, 6, 7, 8, 9),
      cluster_with_nodes(12, 13, 14, 15, 16, 17, 18, 19),
    }
    local links = {
      {type = "coupler", cluster_a = 1, anchor_a = 9, cluster_b = 2, anchor_b = 12},
    }
    topology.build_topology(cs, links, ref)
    return cs
  end
  local h_ref_in_a = topology.compute_hash(mk(3))   -- ref in first cluster
  local h_ref_in_b = topology.compute_hash(mk(15))  -- ref in second cluster
  assert(h_ref_in_a ~= h_ref_in_b,
    "hash should differ when root assignment differs")
end

return T
