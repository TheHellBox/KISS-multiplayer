-- Cluster frame math — Phase 1.
--
-- Pure-math helpers for computing each cluster's spawn-time reference
-- frame: mass-weighted centroid, per-node offsets from the centroid,
-- and the inertia tensor about the centroid. Per spec §3.1 and §4.5.
--
-- These functions take explicit inputs (tables of positions and
-- masses keyed by cid) and return pure data. They have no BeamNG
-- runtime dependency and are unit-tested in isolation.
--
-- The spawn-time wrapper that calls these with obj:getNodePosition
-- / obj:getNodeMass lives elsewhere and is smoke-tested via real
-- vehicle spawns in-game.

local M = {}

print("[KISS_CLUSTER] cluster_frames.lua module body executing")

-- Local 3x3 matrix helper. BeamNG's vehicle Lua environment does
-- NOT expose `mat3` as a global (the GE side has one; the vehicle
-- side doesn't). To keep this module pure Lua without depending on
-- whatever matrix library happens to be loaded, we define a tiny
-- local shape that has the minimum methods the mod needs:
--   :get(row, col) → scalar
--   :trace()       → scalar
--   :transpose()   → new matrix
-- plus the raw .m array (1-indexed, row-major 1..9) for any code
-- that needs to iterate directly.
--
-- This matches the test stub in tests/lua/stubs/beamng_types.lua so
-- existing unit tests pass unchanged.
local mat3_mt = {}
mat3_mt.__index = mat3_mt

function mat3_mt:get(r, c)
  return self.m[(r - 1) * 3 + c]
end

function mat3_mt:trace()
  return self.m[1] + self.m[5] + self.m[9]
end

function mat3_mt:transpose()
  local m = self.m
  return setmetatable({m = {
    m[1], m[4], m[7],
    m[2], m[5], m[8],
    m[3], m[6], m[9],
  }}, mat3_mt)
end

local function make_mat3(entries)
  return setmetatable({m = {
    entries[1], entries[2], entries[3],
    entries[4], entries[5], entries[6],
    entries[7], entries[8], entries[9],
  }}, mat3_mt)
end

-- ============================================================
-- compute_centroid(cluster_node_cids, positions, masses)
--   cluster_node_cids: array of cids in the cluster
--   positions: table cid -> vec3 (world-space position at spawn)
--   masses:    table cid -> number (kg)
-- Returns: centroid_vec3, total_mass
-- ============================================================
function M.compute_centroid(cluster_node_cids, positions, masses)
  local sum_x, sum_y, sum_z = 0, 0, 0
  local total_mass = 0
  for _, cid in ipairs(cluster_node_cids) do
    local p = positions[cid]
    local m = masses[cid] or 0
    sum_x = sum_x + p.x * m
    sum_y = sum_y + p.y * m
    sum_z = sum_z + p.z * m
    total_mass = total_mass + m
  end
  if total_mass <= 0 then
    -- Degenerate — return origin to avoid NaN. Caller should
    -- handle this case (shouldn't happen in practice).
    return vec3(0, 0, 0), 0
  end
  return vec3(sum_x / total_mass, sum_y / total_mass, sum_z / total_mass), total_mass
end

-- ============================================================
-- compute_offsets(cluster_node_cids, positions, centroid)
--   Returns: table cid -> vec3 (each node's offset from centroid)
-- ============================================================
function M.compute_offsets(cluster_node_cids, positions, centroid)
  local offsets = {}
  for _, cid in ipairs(cluster_node_cids) do
    local p = positions[cid]
    offsets[cid] = vec3(p.x - centroid.x, p.y - centroid.y, p.z - centroid.z)
  end
  return offsets
end

-- ============================================================
-- compute_inertia_tensor(cluster_node_cids, offsets, masses)
--   Computes the 3x3 inertia tensor about the centroid using the
--   already-computed per-node offsets.
--
--   I[i][j] = sum(m * (delta_ij * |r|² - r_i * r_j))
--
--   Expanded form (symmetric):
--     Ixx = Σ m * (y² + z²)
--     Iyy = Σ m * (x² + z²)
--     Izz = Σ m * (x² + y²)
--     Ixy = Iyx = -Σ m * x * y
--     Ixz = Izx = -Σ m * x * z
--     Iyz = Izy = -Σ m * y * z
--
--   Returns: mat3
-- ============================================================
function M.compute_inertia_tensor(cluster_node_cids, offsets, masses)
  local Ixx, Iyy, Izz = 0, 0, 0
  local Ixy, Ixz, Iyz = 0, 0, 0
  for _, cid in ipairs(cluster_node_cids) do
    local r = offsets[cid]
    local m = masses[cid] or 0
    local xx = r.x * r.x
    local yy = r.y * r.y
    local zz = r.z * r.z
    Ixx = Ixx + m * (yy + zz)
    Iyy = Iyy + m * (xx + zz)
    Izz = Izz + m * (xx + yy)
    Ixy = Ixy - m * r.x * r.y
    Ixz = Ixz - m * r.x * r.z
    Iyz = Iyz - m * r.y * r.z
  end
  return make_mat3({
    Ixx, Ixy, Ixz,
    Ixy, Iyy, Iyz,
    Ixz, Iyz, Izz,
  })
end

return M
