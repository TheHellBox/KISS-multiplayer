-- Cluster topology — Phase 1.
--
-- Builds the parent-child tree over clusters produced by
-- cluster_discovery. Per spec §4.2:
--
--   1. For each semantic boundary element (coupler/hydro/slidenode)
--      find the two clusters it connects (one per endpoint).
--   2. Root cluster = cluster containing the ref node.
--   3. BFS from root; assign parent_id = closer-to-root in BFS tree.
--   4. Disconnected clusters become their own roots (logged).
--
-- Also implements the topology hash (spec §4.4), used for late-join
-- consistency checks.
--
-- Public API:
--   build_topology(clusters, links, ref_node_cid)
--     Mutates `clusters` in place, adding:
--       c.id, c.is_root, c.parent_id, c.parent_link
--
--   compute_hash(clusters)
--     Returns a deterministic string hash of the cluster structure.
--
-- The `links` argument is a list of cluster-level edges:
--   {
--     type = "coupler" | "hydro" | "slidenode",
--     cluster_a = <1-based index into clusters>,
--     anchor_a  = <node cid in clusters[cluster_a]>,
--     cluster_b = <1-based index into clusters>,
--     anchor_b  = <node cid in clusters[cluster_b]>,
--   }
-- The adapter that converts raw v.data couplers/hydros/slidenodes
-- (which reference nodes, not clusters) into this form lives
-- outside this module and is tested separately.

local M = {}

print("[KISS_CLUSTER] cluster_topology.lua module body executing")

-- ============================================================
-- build_topology
-- ============================================================
function M.build_topology(clusters, links, ref_node_cid)
  -- Assign stable IDs = 1..N based on position in the input list.
  -- cluster_discovery already sorts its output deterministically so
  -- this gives reproducible ids.
  for i, c in ipairs(clusters) do
    c.id = i
    c.is_root = false
    c.parent_id = nil
    c.parent_link = nil
  end

  -- Build cluster-level adjacency from links.
  -- cluster_adj[id] = list of { neighbor_id, link_info }
  local cluster_adj = {}
  for i = 1, #clusters do cluster_adj[i] = {} end
  for _, link in ipairs(links) do
    local a, b = link.cluster_a, link.cluster_b
    if a and b and a ~= b and cluster_adj[a] and cluster_adj[b] then
      -- Store the link symmetrically, but remember which side is
      -- which. When we visit `a -> b`, b's parent_link should
      -- record anchor_node_local = anchor_b, anchor_node_parent =
      -- anchor_a. And vice versa when we visit `b -> a`.
      table.insert(cluster_adj[a], {
        neighbor = b,
        type = link.type,
        anchor_local_for_neighbor = link.anchor_b,
        anchor_local_for_self = link.anchor_a,
      })
      table.insert(cluster_adj[b], {
        neighbor = a,
        type = link.type,
        anchor_local_for_neighbor = link.anchor_a,
        anchor_local_for_self = link.anchor_b,
      })
    end
  end

  -- Find the cluster containing the ref node.
  local root_id = nil
  for i, c in ipairs(clusters) do
    for _, cid in ipairs(c.nodes) do
      if cid == ref_node_cid then
        root_id = i
        break
      end
    end
    if root_id then break end
  end

  if not root_id then
    -- Per spec contract, discover_clusters guarantees the ref is in
    -- some cluster (via fallback). If we still don't find it, it's
    -- a programming error upstream; fall back to cluster 1 being
    -- the root so the function produces a usable result.
    root_id = 1
  end

  -- BFS from the root, assigning parent_id to each visited cluster.
  local visited = {[root_id] = true}
  clusters[root_id].is_root = true
  local queue = {root_id}
  local head = 1
  while head <= #queue do
    local cur = queue[head]
    head = head + 1
    for _, edge in ipairs(cluster_adj[cur]) do
      local nbr = edge.neighbor
      if not visited[nbr] then
        visited[nbr] = true
        clusters[nbr].parent_id = cur
        clusters[nbr].parent_link = {
          type = edge.type,
          -- From the neighbor's perspective: the anchor in its own
          -- cluster is anchor_local_for_neighbor (we're walking
          -- cur -> nbr, so nbr is the neighbor).
          anchor_node_local = edge.anchor_local_for_neighbor,
          anchor_node_parent = edge.anchor_local_for_self,
        }
        table.insert(queue, nbr)
      end
    end
  end

  -- Any cluster not visited is disconnected from the root — log
  -- and mark as its own root. (No warning helper in pure Lua
  -- tests, so just set the flag; runtime wrapper can add logging.)
  for _, c in ipairs(clusters) do
    if not visited[c.id] then
      c.is_root = true
      c.parent_id = nil
      c.parent_link = nil
    end
  end
end

-- ============================================================
-- compute_hash
-- ============================================================
-- Deterministic string hash over the cluster partition + tree
-- structure. Used by the late-join handshake to detect mod-version
-- mismatches between owner and remote.
--
-- For the spec's §4.4 production version, this string would be
-- SHA-256'd to keep it short. Pure Lua has no SHA, so for now we
-- return the canonical string directly — the tests only care
-- about equality/inequality, not cryptographic properties. The
-- runtime wrapper can wrap compute_hash() with a SHA implementation
-- if one is available in the vehicle Lua environment.
function M.compute_hash(clusters)
  local parts = {}
  -- Sort clusters by id for canonical ordering
  local sorted = {}
  for _, c in ipairs(clusters) do table.insert(sorted, c) end
  table.sort(sorted, function(a, b) return a.id < b.id end)

  for _, c in ipairs(sorted) do
    -- Sort nodes within each cluster so order within input
    -- doesn't affect the hash.
    local node_copy = {}
    for i, n in ipairs(c.nodes) do node_copy[i] = n end
    table.sort(node_copy)
    table.insert(parts, string.format(
      "%d:%s:%d",
      c.id,
      table.concat(node_copy, ","),
      c.parent_id or -1
    ))
  end

  return table.concat(parts, "|")
end

return M
