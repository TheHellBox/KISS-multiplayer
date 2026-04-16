-- Cluster discovery — Phase 1.
--
-- Implements the semantic-seeded + stiffness-thresholded connected
-- components algorithm from NodeClusterSync.md §4.1. Given a vehicle's
-- node set, beam list, semantic boundary nodes (couplers/hydros/
-- slidenodes), a ref node, and constants, returns a list of clusters.
--
-- The core algorithm is in `discover_clusters()` which takes explicit
-- inputs and has no BeamNG dependency — it can be unit-tested in
-- isolation. A separate adapter (future: discover_for_vehicle) pulls
-- these inputs from v.data at runtime.
--
-- Clustering rules (summary from spec §4.1):
--   1. Boundary nodes are never in any cluster.
--   2. Beams touching any boundary node are excluded from the
--      adjacency graph.
--   3. Beams below STIFFNESS_THRESHOLD are excluded.
--   4. Connected components of the remaining graph are cluster
--      candidates.
--   5. Candidates smaller than MIN_CLUSTER_SIZE are dropped.
--   6. If no valid cluster contains the ref node (either because the
--      ref is a boundary node, or because its component was filtered
--      out), fall back to a single whole-vehicle cluster.
--
-- Output shape (per cluster):
--   { nodes = {cid1, cid2, ...} }
-- Future phases (centroid, inertia tensor, per-node offsets) will
-- extend this.

local M = {}

print("[KISS_CLUSTER] cluster_discovery.lua module body executing")

-- ============================================================
-- discover_clusters(nodes, beams, boundary, ref_node_cid, const)
-- ============================================================
-- nodes:         list of node cids (integers)
-- beams:         list of { id1, id2, spring } tables
-- boundary:      set of cids (table keyed by cid, value = true),
--                OR list of cids (converted internally)
-- ref_node_cid:  the cid of the vehicle's ref node
-- const:         { STIFFNESS_THRESHOLD = N, MIN_CLUSTER_SIZE = N }
--
-- Returns: list of clusters, each { nodes = {cid, ...} }.
-- Order is deterministic: clusters are sorted by their smallest cid
-- (ascending), and within each cluster the nodes are sorted ascending
-- too. This ensures `discover_clusters` is pure and input-order-
-- invariant for the partition itself.
function M.discover_clusters(nodes, beams, boundary, ref_node_cid, const)
  local STIFFNESS_THRESHOLD = const.STIFFNESS_THRESHOLD
  local MIN_CLUSTER_SIZE = const.MIN_CLUSTER_SIZE

  -- Normalize `boundary` to a set: { [cid] = true }.
  local boundary_set = {}
  if boundary then
    for k, v in pairs(boundary) do
      if v == true then
        boundary_set[k] = true
      else
        -- list form: boundary[i] = cid
        boundary_set[v] = true
      end
    end
  end

  -- Build the adjacency graph from non-boundary, above-threshold beams.
  -- adj[cid] = { neighbor_cid, neighbor_cid, ... }
  local adj = {}
  -- Initialize adj entries for every non-boundary node so they're
  -- seen by the walk, even if they have no qualifying beams.
  for _, cid in ipairs(nodes) do
    if not boundary_set[cid] then
      adj[cid] = {}
    end
  end
  for _, beam in ipairs(beams) do
    local spring = beam.spring or 0
    local id1, id2 = beam.id1, beam.id2
    if spring >= STIFFNESS_THRESHOLD
       and not boundary_set[id1]
       and not boundary_set[id2]
       and adj[id1] and adj[id2]  -- both endpoints present in nodes
    then
      table.insert(adj[id1], id2)
      table.insert(adj[id2], id1)
    end
  end

  -- Deterministic iteration order for connected components: sort the
  -- node cids ascending. Each component is seeded from the smallest
  -- unvisited cid, and within-component traversal also processes
  -- neighbors in ascending order (via table.sort).
  local sorted_non_boundary = {}
  for _, cid in ipairs(nodes) do
    if not boundary_set[cid] then
      table.insert(sorted_non_boundary, cid)
    end
  end
  table.sort(sorted_non_boundary)

  local visited = {}
  local components = {}
  for _, seed in ipairs(sorted_non_boundary) do
    if not visited[seed] then
      local component = {}
      local stack = {seed}
      while #stack > 0 do
        local n = table.remove(stack)
        if not visited[n] then
          visited[n] = true
          table.insert(component, n)
          -- Sort neighbors descending so that smallest is popped last
          -- (stack is LIFO); combined with the seed ordering this
          -- gives deterministic traversal.
          local neighbors = adj[n]
          if neighbors and #neighbors > 0 then
            local sorted_nbrs = {}
            for i = 1, #neighbors do sorted_nbrs[i] = neighbors[i] end
            table.sort(sorted_nbrs, function(a, b) return a > b end)
            for _, nbr in ipairs(sorted_nbrs) do
              if not visited[nbr] then
                table.insert(stack, nbr)
              end
            end
          end
        end
      end
      table.sort(component)
      table.insert(components, component)
    end
  end

  -- Filter to clusters ≥ MIN_CLUSTER_SIZE.
  local valid_clusters = {}
  for _, comp in ipairs(components) do
    if #comp >= MIN_CLUSTER_SIZE then
      table.insert(valid_clusters, {nodes = comp})
    end
  end

  -- Sort clusters deterministically by their smallest cid.
  table.sort(valid_clusters, function(a, b) return a.nodes[1] < b.nodes[1] end)

  -- Ref node sanity check. If the ref node is a boundary node, or is
  -- in a component that got filtered out, fall back to a single
  -- whole-vehicle cluster.
  local ref_in_valid = false
  for _, c in ipairs(valid_clusters) do
    for _, cid in ipairs(c.nodes) do
      if cid == ref_node_cid then
        ref_in_valid = true
        break
      end
    end
    if ref_in_valid then break end
  end

  if #valid_clusters == 0 or not ref_in_valid then
    -- Fallback: one cluster containing every node (including boundary
    -- nodes — we want the vehicle to still sync as a single rigid
    -- body).
    local all = {}
    for _, cid in ipairs(nodes) do
      table.insert(all, cid)
    end
    table.sort(all)
    return {{nodes = all}}
  end

  return valid_clusters
end

return M
