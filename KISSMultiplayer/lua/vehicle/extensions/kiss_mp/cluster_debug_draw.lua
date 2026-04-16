-- Cluster debug overlay — Phase 1.
--
-- Draws a wireframe axis-aligned bounding box around each discovered
-- cluster, colored by cluster id using the golden-angle hue sequence
-- (spec §7.1). Runs every GFX update, reads cluster membership from
-- cluster_state.clusters, reads live world positions from obj:*, and
-- draws via obj.debugDrawProxy.
--
-- Toggle off by setting M.enabled = false at runtime. On by default
-- once cluster_state has data.

local M = {}

print("[KISS_CLUSTER] cluster_debug_draw.lua module body executing")

M.enabled = true
M.show_labels = true
M.show_centroid_spheres = true
M.edge_radius = 0.025  -- meters
M.centroid_sphere_radius = 0.15

-- View mode. One of:
--   "clusters"  — only the rigid-body cluster AABBs (default)
--   "regions"   — only the JBeam-group region AABBs (thinner edges,
--                 pastel colors, no centroid spheres)
--   "both"      — both overlaid; clusters on top of regions
-- Toggle at runtime via M.view_mode = "regions" from the Lua
-- console, or cycle with M.cycle_view_mode().
M.view_mode = "clusters"
M.region_edge_radius = 0.012

-- ============================================================
-- HSV → RGB conversion (pure math, standard algorithm)
-- ============================================================
-- h in [0, 360), s and v in [0, 1]. Returns r, g, b in [0, 255].
local function hsv_to_rgb(h, s, v)
  h = h % 360
  local c = v * s
  local x = c * (1 - math.abs(((h / 60) % 2) - 1))
  local m = v - c
  local r1, g1, b1
  if h < 60       then r1, g1, b1 = c, x, 0
  elseif h < 120  then r1, g1, b1 = x, c, 0
  elseif h < 180  then r1, g1, b1 = 0, c, x
  elseif h < 240  then r1, g1, b1 = 0, x, c
  elseif h < 300  then r1, g1, b1 = x, 0, c
  else                 r1, g1, b1 = c, 0, x end
  return math.floor((r1 + m) * 255 + 0.5),
         math.floor((g1 + m) * 255 + 0.5),
         math.floor((b1 + m) * 255 + 0.5)
end

-- Deterministic color per cluster id using the golden-angle hue
-- sequence. Gives visually distinct colors even for many clusters.
local GOLDEN_ANGLE_DEG = 137.508
local function cluster_color(cluster_id)
  local hue = ((cluster_id - 1) * GOLDEN_ANGLE_DEG) % 360
  return hsv_to_rgb(hue, 1.0, 1.0)
end

-- Deterministic pastel color per region name. Hash the name to a
-- hue so colors stay stable across spawns. Saturation/value tuned
-- down from cluster colors so regions visually recede when drawn
-- together with clusters.
local function region_color(name)
  local h = 0
  for i = 1, #name do
    h = (h * 31 + string.byte(name, i)) % 360
  end
  return hsv_to_rgb(h, 0.55, 0.95)
end

-- ============================================================
-- Compute world-space AABB for a live node set. Used for the
-- region overlay (which has no rotation to track — JBeam groups
-- are purely a partition) and as a fallback for clusters that
-- don't have a cached local AABB.
-- ============================================================
local function compute_world_aabb(cluster)
  local mins = {x = math.huge, y = math.huge, z = math.huge}
  local maxs = {x = -math.huge, y = -math.huge, z = -math.huge}
  local count = 0
  local sum_x, sum_y, sum_z = 0, 0, 0
  local base = vec3(obj:getPosition())
  for _, cid in ipairs(cluster.nodes) do
    local ok, off = pcall(function() return vec3(obj:getNodePosition(cid)) end)
    if ok and off then
      local wx = base.x + off.x
      local wy = base.y + off.y
      local wz = base.z + off.z
      if wx < mins.x then mins.x = wx end
      if wy < mins.y then mins.y = wy end
      if wz < mins.z then mins.z = wz end
      if wx > maxs.x then maxs.x = wx end
      if wy > maxs.y then maxs.y = wy end
      if wz > maxs.z then maxs.z = wz end
      sum_x = sum_x + wx
      sum_y = sum_y + wy
      sum_z = sum_z + wz
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return mins, maxs, vec3(sum_x / count, sum_y / count, sum_z / count)
end

-- ============================================================
-- Compute the cluster's LOCAL-frame AABB from its spawn-time
-- node_offsets_local. These offsets are constant per cluster, so
-- we can cache the AABB on the cluster table itself and only
-- recompute on reset.
--
-- Returns (mins, maxs) as vec3s in the cluster local frame.
-- ============================================================
local function get_local_aabb(cluster)
  if cluster._local_aabb_mins and cluster._local_aabb_maxs then
    return cluster._local_aabb_mins, cluster._local_aabb_maxs
  end
  if not cluster.node_offsets_local then return nil, nil end
  local mnx, mny, mnz = math.huge, math.huge, math.huge
  local mxx, mxy, mxz = -math.huge, -math.huge, -math.huge
  for _, off in pairs(cluster.node_offsets_local) do
    if off.x < mnx then mnx = off.x end
    if off.y < mny then mny = off.y end
    if off.z < mnz then mnz = off.z end
    if off.x > mxx then mxx = off.x end
    if off.y > mxy then mxy = off.y end
    if off.z > mxz then mxz = off.z end
  end
  if mnx == math.huge then return nil, nil end
  cluster._local_aabb_mins = vec3(mnx, mny, mnz)
  cluster._local_aabb_maxs = vec3(mxx, mxy, mxz)
  return cluster._local_aabb_mins, cluster._local_aabb_maxs
end

-- ============================================================
-- Compute the live world pose (centroid + rotation) for the
-- cluster. Used so the OBB wireframe rotates with the chassis.
--
-- Rotation source: obj:getRotation(). This is the whole-vehicle
-- world rotation, which is correct for rigid clusters (every
-- cluster on a non-articulated vehicle tracks the vehicle's
-- rotation). For articulated vehicles with multiple rigid clusters
-- moving relative to each other (tow-truck deck, bus hinge), each
-- non-root cluster would need its own Horn fit — that's a Phase 3
-- concern. For Phase 1/2 debug overlay on rigid vehicles,
-- obj:getRotation() is the simplest correct answer.
--
-- Centroid: live mass-weighted mean of world node positions.
-- ============================================================
local function compute_cluster_world_pose(cluster)
  local masses = cluster.masses
  if not masses then return nil, nil end
  local base = vec3(obj:getPosition())
  local cx, cy, cz, total = 0, 0, 0, 0
  for _, cid in ipairs(cluster.nodes) do
    local m = masses[cid] or 0
    if m > 0 then
      local ok, off = pcall(function() return vec3(obj:getNodePosition(cid)) end)
      if ok and off then
        cx = cx + (base.x + off.x) * m
        cy = cy + (base.y + off.y) * m
        cz = cz + (base.z + off.z) * m
        total = total + m
      end
    end
  end
  if total <= 0 then return nil, nil end
  local centroid = vec3(cx / total, cy / total, cz / total)
  local rot = quat(obj:getRotation())
  return centroid, rot
end

-- Draw a cylinder from a to b in the given color.
local function draw_edge(a, b, radius, col)
  obj.debugDrawProxy:drawCylinder(
    float3(a.x, a.y, a.z),
    float3(b.x, b.y, b.z),
    radius,
    col
  )
end

-- Draw 12 edges of an axis-aligned bounding box.
local function draw_aabb_wireframe(mins, maxs, radius, col)
  local x0, y0, z0 = mins.x, mins.y, mins.z
  local x1, y1, z1 = maxs.x, maxs.y, maxs.z
  -- 8 corners
  local c = {
    {x = x0, y = y0, z = z0},  -- 1
    {x = x1, y = y0, z = z0},  -- 2
    {x = x1, y = y1, z = z0},  -- 3
    {x = x0, y = y1, z = z0},  -- 4
    {x = x0, y = y0, z = z1},  -- 5
    {x = x1, y = y0, z = z1},  -- 6
    {x = x1, y = y1, z = z1},  -- 7
    {x = x0, y = y1, z = z1},  -- 8
  }
  -- 12 edges
  local edges = {
    {1,2},{2,3},{3,4},{4,1},  -- bottom rect
    {5,6},{6,7},{7,8},{8,5},  -- top rect
    {1,5},{2,6},{3,7},{4,8},  -- verticals
  }
  for _, e in ipairs(edges) do
    draw_edge(c[e[1]], c[e[2]], radius, col)
  end
end

-- ============================================================
-- Draw an ORIENTED bounding box: take a local-frame AABB, rotate
-- the 8 corners by the given world rotation, then translate by
-- the world centroid. The result is a rigid box that tracks the
-- cluster's rotation visually — it tilts and yaws with the
-- chassis instead of growing/shrinking as the car turns.
-- ============================================================
local function draw_obb_wireframe(mins_local, maxs_local, centroid_world, rot, radius, col)
  local x0, y0, z0 = mins_local.x, mins_local.y, mins_local.z
  local x1, y1, z1 = maxs_local.x, maxs_local.y, maxs_local.z
  local locals = {
    vec3(x0, y0, z0), vec3(x1, y0, z0),
    vec3(x1, y1, z0), vec3(x0, y1, z0),
    vec3(x0, y0, z1), vec3(x1, y0, z1),
    vec3(x1, y1, z1), vec3(x0, y1, z1),
  }
  local c = {}
  for i, l in ipairs(locals) do
    c[i] = centroid_world + rot * l
  end
  local edges = {
    {1,2},{2,3},{3,4},{4,1},
    {5,6},{6,7},{7,8},{8,5},
    {1,5},{2,6},{3,7},{4,8},
  }
  for _, e in ipairs(edges) do
    draw_edge(c[e[1]], c[e[2]], radius, col)
  end
end

-- Draw a line from a child cluster's centroid to its parent
-- cluster's centroid, in the child's color. Helps visualize the
-- topology tree.
local function draw_parent_link(cluster, centroids)
  if not cluster.parent_id then return end
  local parent_centroid = centroids[cluster.parent_id]
  local own_centroid = centroids[cluster.id]
  if not parent_centroid or not own_centroid then return end
  local r, g, b = cluster_color(cluster.id)
  local col = color(r, g, b, 180)
  draw_edge(own_centroid, parent_centroid, M.edge_radius * 0.8, col)
end

-- ============================================================
-- updateGFX — per-frame draw hook
-- ============================================================
-- Draw every region as a thin wireframe AABB + label at centroid.
-- Called before cluster drawing when in "regions" or "both" mode.
local function draw_regions()
  if not cluster_state or not cluster_state.regions then return end
  if #cluster_state.regions == 0 then return end
  for _, r in ipairs(cluster_state.regions) do
    local mins, maxs, centroid = compute_world_aabb({nodes = r.nodes})
    if mins then
      local cr, cg, cb = region_color(r.name)
      local edge_col = color(cr, cg, cb, 200)
      draw_aabb_wireframe(mins, maxs, M.region_edge_radius, edge_col)
      if M.show_labels and obj.debugDrawProxy.drawTextAdvanced then
        pcall(function()
          obj.debugDrawProxy:drawTextAdvanced(
            float3(centroid.x, centroid.y + 0.25, centroid.z),
            string.format("%s (%d)", r.name, #r.nodes),
            color(cr, cg, cb, 255),
            true, false,
            color(0, 0, 0, 140)
          )
        end)
      end
    end
  end
end

local function updateGFX(dt)
  if not M.enabled then return end
  if not cluster_state then return end
  if not obj or not obj.debugDrawProxy then return end

  local mode = M.view_mode or "clusters"
  local show_clusters = (mode == "clusters" or mode == "both")
  local show_regions  = (mode == "regions"  or mode == "both")

  if show_regions then draw_regions() end

  if not show_clusters then return end
  if not cluster_state.clusters or #cluster_state.clusters == 0 then return end

  -- First pass: compute per-cluster world pose (Horn best-fit
  -- rotation + mass-weighted centroid) so the OBB tracks the
  -- cluster's orientation. Fall back to live-AABB if cluster_math
  -- isn't loaded yet.
  local poses = {}    -- [id] = {centroid, rot}
  local centroids = {}
  for _, c in ipairs(cluster_state.clusters) do
    local centroid, rot = compute_cluster_world_pose(c)
    if centroid and rot then
      poses[c.id] = {centroid = centroid, rot = rot}
      centroids[c.id] = centroid
    else
      -- Fallback: world AABB only, used for centroid + label
      local _, _, fallback_centroid = compute_world_aabb(c)
      if fallback_centroid then centroids[c.id] = fallback_centroid end
    end
  end

  -- Second pass: draw wireframes + optional centroid spheres
  for _, c in ipairs(cluster_state.clusters) do
    local pose = poses[c.id]
    if pose then
      local mins_local, maxs_local = get_local_aabb(c)
      local r, g, b = cluster_color(c.id)
      local edge_col = color(r, g, b, 255)
      if mins_local then
        draw_obb_wireframe(mins_local, maxs_local, pose.centroid, pose.rot,
                           M.edge_radius, edge_col)
      end

      if M.show_centroid_spheres then
        local centroid = centroids[c.id]
        if centroid then
          obj.debugDrawProxy:drawSphere(
            M.centroid_sphere_radius,
            float3(centroid.x, centroid.y, centroid.z),
            color(r, g, b, 200)
          )
        end
      end

      if M.show_labels and centroids[c.id] then
        local centroid = centroids[c.id]
        local label = string.format(
          "C%d %d nodes %.0fkg%s",
          c.id, #c.nodes, c.total_mass or 0,
          c.parent_id and (" parent=" .. c.parent_id) or " (root)"
        )
        -- drawTextAdvanced may not be available on all BeamNG
        -- versions. Guard it so missing method doesn't crash the
        -- whole updateGFX loop.
        if obj.debugDrawProxy.drawTextAdvanced then
          local ok, _ = pcall(function()
            obj.debugDrawProxy:drawTextAdvanced(
              float3(centroid.x, centroid.y + 0.5, centroid.z),
              label,
              color(255, 255, 255, 255),
              true,  -- drawBackground
              false, -- cullFacing
              color(0, 0, 0, 160)
            )
          end)
        end
      end
    end
  end

  -- Third pass: parent-child link lines
  for _, c in ipairs(cluster_state.clusters) do
    draw_parent_link(c, centroids)
  end
end

-- Cycle view_mode: clusters → regions → both → clusters. Bind this
-- to a hotkey or call from the Lua console to flip overlays in
-- game without editing the file.
local VIEW_MODES = {"clusters", "regions", "both"}
function M.cycle_view_mode()
  local cur = M.view_mode or "clusters"
  for i, m in ipairs(VIEW_MODES) do
    if m == cur then
      M.view_mode = VIEW_MODES[(i % #VIEW_MODES) + 1]
      print("[KISS_CLUSTER] cluster_debug_draw.view_mode = " .. M.view_mode)
      return
    end
  end
  M.view_mode = "clusters"
end

M.updateGFX = updateGFX
M.cluster_color = cluster_color  -- exposed for potential reuse / tests
M.region_color = region_color    -- exposed for potential reuse / tests
M.hsv_to_rgb = hsv_to_rgb        -- exposed for potential reuse / tests

return M
