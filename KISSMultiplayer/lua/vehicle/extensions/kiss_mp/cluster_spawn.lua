-- Cluster spawn-time integration — Phase 1.
--
-- Bridge between the pure cluster math (cluster_discovery,
-- cluster_topology, cluster_frames) and BeamNG's runtime API. Runs
-- once at vehicle extension load, reads v.data + obj:*, computes the
-- cluster partition, topology, per-cluster centroid/inertia, and
-- stores the result in cluster_state.clusters.
--
-- This is the piece that cannot be unit-tested in isolation (it
-- touches obj and v.data) — validation is via in-game smoke tests
-- after the other modules are confirmed green via `lua
-- tests/lua/run_tests.lua`.

local M = {}

-- DIAGNOSTIC: print at module load time so we can see whether
-- this file is even being parsed by BeamNG.
print("[KISS_CLUSTER] cluster_spawn.lua module body executing")

-- ============================================================
-- extract_boundary_nodes(vdata)
--   Walks v.data for nodes that should be semantic boundaries:
--     * nodes with couplerTag set (ball hitches, fifth wheels, etc)
--     * advancedCouplerControl-controlled couplers
--     * hydro endpoints (steering, suspension, tilt pistons)
--     * slidenode rail nodes
--   Returns: set { [cid] = true } of boundary node cids.
--
-- This is defensive — BeamNG's jbeam data shape varies across
-- vehicles and mod versions. We handle each field category
-- gracefully if absent. Tag into a log to help diagnose weird
-- vehicles in the field.
-- ============================================================
local function extract_boundary_nodes(vdata)
  local boundary = {}
  if not vdata then return boundary end

  -- 1. Nodes with a couplerTag field (ball hitches, pintle,
  --    fifth wheel receiver). These are the most common case.
  if vdata.nodes then
    for _, node in pairs(vdata.nodes) do
      if type(node) == "table" and node.couplerTag and node.couplerTag ~= "" and node.cid then
        boundary[node.cid] = true
      end
    end
  end

  -- 2. Hydro endpoints (steering linkage, suspension travel,
  --    tilt bed pistons). Hydros deliberately change length at
  --    runtime, so their endpoints should be cluster boundaries.
  if vdata.hydros then
    for _, h in pairs(vdata.hydros) do
      if type(h) == "table" then
        if h.id1 then boundary[h.id1] = true end
        if h.id2 then boundary[h.id2] = true end
        -- Some hydro formats use cid1/cid2
        if h.cid1 then boundary[h.cid1] = true end
        if h.cid2 then boundary[h.cid2] = true end
      end
    end
  end

  -- 3. Slidenodes — nodes attached to rails that can slide.
  if vdata.slidenodes then
    for _, sn in pairs(vdata.slidenodes) do
      if type(sn) == "table" then
        -- slidenodes reference a node that moves along a set of rail nodes
        if sn.id1 then boundary[sn.id1] = true end
        if sn.id2 then boundary[sn.id2] = true end
        if sn.cid then boundary[sn.cid] = true end
        if sn.nodes then
          for _, n in pairs(sn.nodes) do
            if type(n) == "number" then boundary[n] = true end
          end
        end
      end
    end
  end

  -- 4. advancedCouplerControl nodes, via v.data.controller entries.
  --    Pattern from kiss_electrics.lua:
  if vdata.controller and type(vdata.controller) == "table" then
    for _, controller_data in pairs(vdata.controller) do
      if type(controller_data) == "table"
         and controller_data.fileName == "advancedCouplerControl"
         and controller_data.couplerNodes then
        -- couplerNodes is typically a tableFromHeaderTable format.
        -- Iterate defensively without assuming a specific shape.
        local iter = controller_data.couplerNodes
        if type(iter) == "table" then
          for _, vn in pairs(iter) do
            if type(vn) == "table" then
              -- Try several field names seen in the wild
              for _, field in ipairs({"cid1", "cid2", "id1", "id2"}) do
                local v = vn[field]
                -- Some jbeams use node NAMES, which need to be
                -- mapped via beamstate.nodeNameMap to numeric cids.
                if type(v) == "number" then
                  boundary[v] = true
                elseif type(v) == "string" and beamstate and beamstate.nodeNameMap then
                  local cid = beamstate.nodeNameMap[v]
                  if cid then boundary[cid] = true end
                end
              end
            end
          end
        end
      end
    end
  end

  return boundary
end

-- ============================================================
-- extract_beams(vdata)
--   Walks v.data.beams and returns a list of {id1, id2, spring}
--   tables ready for cluster_discovery.discover_clusters.
-- ============================================================
local function extract_beams(vdata)
  local beams = {}
  if not vdata or not vdata.beams then return beams end
  for _, b in pairs(vdata.beams) do
    if type(b) == "table" and b.id1 and b.id2 then
      local spring = b.beamSpring or b.spring or 0
      table.insert(beams, {id1 = b.id1, id2 = b.id2, spring = spring})
    end
  end
  return beams
end

-- ============================================================
-- extract_node_cids(vdata)
--   Returns: flat list of node cids found in v.data.nodes.
-- ============================================================
local function extract_node_cids(vdata)
  local cids = {}
  if not vdata or not vdata.nodes then return cids end
  for _, node in pairs(vdata.nodes) do
    if type(node) == "table" and node.cid then
      table.insert(cids, node.cid)
    end
  end
  return cids
end

-- ============================================================
-- extract_regions(vdata)
--   Partition nodes into semantic regions for the debug overlay
--   and the Phase 10 damage-sync LOD reservation.
--
--   Primary partition key: `partOrigin` — the JBeam part path the
--   node was loaded from. Reliably populated by BeamNG's JBeam
--   parser on every node, and gives the granularity we want
--   (each body panel, bumper, engine module, suspension subframe
--   etc. is usually its own part). We strip path components down
--   to the leaf file name so colors stay readable.
--
--   Fallback: `group` field if it's populated and non-empty.
--   Older or simpler vehicles may not split their JBeam across
--   many parts but do use `group` extensively.
--
--   Ultimate fallback: "(ungrouped)".
--
--   Returns: list of { name, nodes } records in name-sorted order.
-- ============================================================
local function leaf_name(path)
  if type(path) ~= "string" or path == "" then return nil end
  -- Strip directory prefix and any .jbeam extension.
  local name = path:match("([^/\\]+)$") or path
  name = name:gsub("%.jbeam$", "")
  return name
end

local function extract_regions(vdata)
  if not vdata or not vdata.nodes then return {} end
  local by_name = {}
  for _, node in pairs(vdata.nodes) do
    if type(node) == "table" and node.cid then
      local name = leaf_name(node.partOrigin)
      if not name then
        local g = node.group
        if type(g) == "string" and g ~= "" then
          name = g
        elseif type(g) == "table" then
          for _, gg in ipairs(g) do
            if type(gg) == "string" and gg ~= "" then name = gg; break end
          end
        end
      end
      name = name or "(ungrouped)"
      by_name[name] = by_name[name] or {name = name, nodes = {}}
      table.insert(by_name[name].nodes, node.cid)
    end
  end
  local list = {}
  for _, r in pairs(by_name) do table.insert(list, r) end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- ============================================================
-- get_ref_node_cid(vdata)
--   Returns: cid of the vehicle's reference node, or nil.
-- ============================================================
local function get_ref_node_cid(vdata)
  if not vdata or not vdata.refNodes then return nil end
  local rn = vdata.refNodes[0]
  if type(rn) ~= "table" then return nil end
  return rn.ref
end

-- ============================================================
-- build_cluster_level_links(clusters, vdata)
--   For each semantic boundary element in v.data, find which two
--   clusters it connects by walking the beam graph from each
--   endpoint outward until we hit a non-boundary node that belongs
--   to a cluster.
--
--   Returns a list of cluster-level link records suitable for
--   cluster_topology.build_topology.
--
-- Phase 1 note: the full "find nearest cluster via beam BFS from a
-- boundary node" search is moderately involved. For the first pass
-- we use a simpler heuristic: for each boundary node, look at its
-- direct beam neighbors. If a direct neighbor is in some cluster,
-- record that cluster as one end of the link. If the two endpoints
-- of a semantic element end up in different clusters, emit a link.
-- This covers the common case (coupler between two rigid frames)
-- without the full BFS; vehicles that don't fit this pattern will
-- simply not produce cross-cluster links and will sync as
-- independent clusters, which is still correct just less optimal.
-- ============================================================
local function build_cluster_level_links(clusters, vdata)
  -- Build cid -> cluster_index lookup from clusters.
  local cid_to_cluster_idx = {}
  for i, c in ipairs(clusters) do
    for _, cid in ipairs(c.nodes) do
      cid_to_cluster_idx[cid] = i
    end
  end

  -- Build a map from node cid to its direct beam neighbors.
  local neighbors = {}
  if vdata and vdata.beams then
    for _, b in pairs(vdata.beams) do
      if type(b) == "table" and b.id1 and b.id2 then
        neighbors[b.id1] = neighbors[b.id1] or {}
        neighbors[b.id2] = neighbors[b.id2] or {}
        table.insert(neighbors[b.id1], b.id2)
        table.insert(neighbors[b.id2], b.id1)
      end
    end
  end

  -- Find the cluster a given boundary node is adjacent to. Looks
  -- at direct neighbors and returns the first one that's in a
  -- cluster, plus the anchor cid (the neighbor node itself).
  local function find_adjacent_cluster(boundary_cid)
    local nbrs = neighbors[boundary_cid]
    if not nbrs then return nil, nil end
    for _, nbr in ipairs(nbrs) do
      local idx = cid_to_cluster_idx[nbr]
      if idx then return idx, nbr end
    end
    return nil, nil
  end

  local links = {}

  -- Helper: emit a link given two boundary cids + a type label.
  local function try_emit_link(label, b_a, b_b)
    if not b_a or not b_b then return end
    local idx_a, anchor_a = find_adjacent_cluster(b_a)
    local idx_b, anchor_b = find_adjacent_cluster(b_b)
    if idx_a and idx_b and idx_a ~= idx_b then
      table.insert(links, {
        type = label,
        cluster_a = idx_a, anchor_a = anchor_a,
        cluster_b = idx_b, anchor_b = anchor_b,
      })
    end
  end

  -- Couplers: endpoints come from v.data.couplers or
  -- advancedCouplerControl. For couplerTag-marked nodes we don't
  -- know the pairing at spawn (runtime coupling is dynamic), so
  -- those produce no spawn-time links — they'll be added by
  -- runtime CouplerAttached events later.
  if vdata and vdata.hydros then
    for _, h in pairs(vdata.hydros) do
      if type(h) == "table" then
        local a = h.id1 or h.cid1
        local b = h.id2 or h.cid2
        try_emit_link("hydro", a, b)
      end
    end
  end
  if vdata and vdata.slidenodes then
    for _, sn in pairs(vdata.slidenodes) do
      if type(sn) == "table" then
        local a = sn.id1 or sn.cid
        local b = sn.id2
        try_emit_link("slidenode", a, b)
      end
    end
  end

  return links
end

-- ============================================================
-- run_spawn_clustering()
--   Called from onExtensionLoaded. Reads v.data + obj:*, runs the
--   full pipeline, and populates cluster_state.clusters +
--   topology_hash.
-- ============================================================
local function run_spawn_clustering()
  if not cluster_state or not cluster_discovery or not cluster_topology or not cluster_frames then
    -- Dependencies not loaded yet. Log the state so we can
    -- see what's missing rather than failing silently.
    print(string.format(
      "[KISS_CLUSTER] deferring: cluster_state=%s discovery=%s topology=%s frames=%s",
      tostring(cluster_state ~= nil),
      tostring(cluster_discovery ~= nil),
      tostring(cluster_topology ~= nil),
      tostring(cluster_frames ~= nil)
    ))
    return false
  end
  if not v or not v.data or not obj then
    print("[KISS_CLUSTER] deferring: v or obj not available yet")
    return false
  end

  local vdata = v.data
  local ref_cid = get_ref_node_cid(vdata)
  if not ref_cid then
    print("[KISS_CLUSTER] no refNode found; skipping cluster discovery")
    return
  end

  local node_cids = extract_node_cids(vdata)
  local beams = extract_beams(vdata)
  local boundary = extract_boundary_nodes(vdata)

  -- Step 1: discover clusters (pure algorithm)
  local const = cluster_state.const
  local clusters = cluster_discovery.discover_clusters(node_cids, beams, boundary, ref_cid, const)

  -- Step 2: build topology (parent-child tree)
  local links = build_cluster_level_links(clusters, vdata)
  cluster_topology.build_topology(clusters, links, ref_cid)

  -- Step 3: compute per-cluster centroid, offsets, inertia tensor.
  -- Read world positions and masses from obj. Convert world
  -- positions to vehicle-local (inverse-rotated by current
  -- orientation) so the offsets are stable regardless of spawn
  -- orientation.
  local inverse_rot = quat(obj:getRotation()):inversed()
  local positions = {}
  local masses = {}
  for _, cid in ipairs(node_cids) do
    positions[cid] = inverse_rot * obj:getNodePosition(cid)
    masses[cid] = obj:getNodeMass(cid)
  end

  for _, c in ipairs(clusters) do
    local centroid, total_mass = cluster_frames.compute_centroid(c.nodes, positions, masses)
    c.centroid_local = centroid
    c.total_mass = total_mass
    c.node_offsets_local = cluster_frames.compute_offsets(c.nodes, positions, centroid)
    c.inertia_local = cluster_frames.compute_inertia_tensor(c.nodes, c.node_offsets_local, masses)
    -- Stash per-node masses for the runtime force path (cluster_receiver).
    -- Avoids calling obj:getNodeMass(cid) every tick. Mass is constant
    -- between resets, so this copy is safe until onReset re-runs.
    local cluster_masses = {}
    for _, cid in ipairs(c.nodes) do cluster_masses[cid] = masses[cid] end
    c.masses = cluster_masses
    c.enabled = true
  end

  -- Store in cluster_state for other modules.
  cluster_state.clusters = clusters
  cluster_state.topology_hash = cluster_topology.compute_hash(clusters)

  -- Region partition from JBeam groups. Independent of clusters —
  -- used by cluster_debug_draw for the switchable region overlay
  -- and reserved for Phase 10 per-region damage-sync LOD.
  cluster_state.regions = extract_regions(vdata)

  print(string.format(
    "[KISS_CLUSTER id=%d] %d regions from JBeam groups",
    obj:getID(), #cluster_state.regions
  ))

  print(string.format(
    "[KISS_CLUSTER id=%d] discovered %d clusters (hash=%s, %d boundary nodes)",
    obj:getID(), #clusters, tostring(cluster_state.topology_hash):sub(1, 40) .. "...",
    (function() local n = 0 for _ in pairs(boundary) do n = n + 1 end return n end)()
  ))
  for i, c in ipairs(clusters) do
    local parent_desc = c.parent_id and ("parent=" .. c.parent_id) or "root"
    print(string.format(
      "  C%d: %d nodes, %.0f kg, %s",
      i, #c.nodes, c.total_mass, parent_desc
    ))
  end
  return true
end

-- ============================================================
-- Extension lifecycle
-- ============================================================
-- Deferred-until-ready pattern: cluster_spawn runs alphabetically
-- before some of its siblings (cluster_state, cluster_topology,
-- etc.) because BeamNG loads extensions in file-name order within
-- a directory. On the first onExtensionLoaded call those
-- dependencies may not yet be resolved as globals. Instead of
-- failing silently, we set a pending flag and retry on every
-- updateGFX tick until the clustering succeeds.
local pending_clustering = true

local function try_clustering_once()
  if not pending_clustering then return end
  if run_spawn_clustering() then
    pending_clustering = false
  end
end

local function onExtensionLoaded()
  pending_clustering = true
  try_clustering_once()
end

-- Re-run clustering after every reset. Clears the pending flag
-- so the retry loop below kicks in if a dependency was unloaded.
local function onReset()
  pending_clustering = true
  try_clustering_once()
end

-- Retry hook — runs every frame until clustering has completed
-- once, then no-ops.
local function updateGFX(dt)
  if pending_clustering then
    try_clustering_once()
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.updateGFX = updateGFX
M.run_spawn_clustering = run_spawn_clustering

-- Exposed for future phases / debug UI:
M.extract_boundary_nodes = extract_boundary_nodes
M.extract_beams = extract_beams
M.extract_node_cids = extract_node_cids
M.extract_regions = extract_regions

return M
