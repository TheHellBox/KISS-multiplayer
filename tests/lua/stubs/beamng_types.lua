-- BeamNG-compatible stubs for vec3 / quat / mat3 and helper globals.
-- Pure Lua. Used by the test harness so we can unit-test the mod's
-- math in isolation without loading BeamNG.
--
-- Only implements the operations the mod actually uses. If a test
-- fails with "attempt to call method 'X' (a nil value)", add the
-- operation here.

local M = {}

-- ============================================================
-- vec3
-- ============================================================
local vec3_mt = {}
vec3_mt.__index = vec3_mt

local function new_vec3(x, y, z)
  -- Support vec3(), vec3(n), vec3(x,y,z), vec3(other_vec3), vec3({x,y,z})
  if x == nil then
    return setmetatable({x = 0, y = 0, z = 0}, vec3_mt)
  elseif type(x) == "table" then
    if x.x ~= nil then
      return setmetatable({x = x.x, y = x.y, z = x.z}, vec3_mt)
    else
      return setmetatable({x = x[1] or 0, y = x[2] or 0, z = x[3] or 0}, vec3_mt)
    end
  else
    return setmetatable({x = x, y = y or 0, z = z or 0}, vec3_mt)
  end
end

function vec3_mt:length()
  return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
end

function vec3_mt:squaredLength()
  return self.x * self.x + self.y * self.y + self.z * self.z
end

function vec3_mt:normalized()
  local len = self:length()
  if len < 1e-12 then return new_vec3(0, 0, 0) end
  return new_vec3(self.x / len, self.y / len, self.z / len)
end

function vec3_mt:dot(other)
  return self.x * other.x + self.y * other.y + self.z * other.z
end

function vec3_mt:cross(other)
  return new_vec3(
    self.y * other.z - self.z * other.y,
    self.z * other.x - self.x * other.z,
    self.x * other.y - self.y * other.x
  )
end

function vec3_mt:distance(other)
  local dx = self.x - other.x
  local dy = self.y - other.y
  local dz = self.z - other.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

vec3_mt.__add = function(a, b)
  return new_vec3(a.x + b.x, a.y + b.y, a.z + b.z)
end

vec3_mt.__sub = function(a, b)
  return new_vec3(a.x - b.x, a.y - b.y, a.z - b.z)
end

vec3_mt.__mul = function(a, b)
  if type(b) == "number" then
    return new_vec3(a.x * b, a.y * b, a.z * b)
  elseif type(a) == "number" then
    return new_vec3(b.x * a, b.y * a, b.z * a)
  else
    error("vec3 * vec3 is ambiguous; use dot/cross explicitly")
  end
end

vec3_mt.__unm = function(a)
  return new_vec3(-a.x, -a.y, -a.z)
end

vec3_mt.__tostring = function(v)
  return string.format("vec3(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
end

vec3_mt.__eq = function(a, b)
  return a.x == b.x and a.y == b.y and a.z == b.z
end

M.vec3 = new_vec3

-- ============================================================
-- quat
-- ============================================================
-- Quaternion (x, y, z, w) with w being the scalar part.
-- Convention: multiplication is right-to-left (Hamilton product).
local quat_mt = {}
quat_mt.__index = quat_mt

local function new_quat(x, y, z, w)
  if x == nil then
    return setmetatable({x = 0, y = 0, z = 0, w = 1}, quat_mt)
  elseif type(x) == "table" then
    return setmetatable({x = x.x or 0, y = x.y or 0, z = x.z or 0, w = x.w or 1}, quat_mt)
  else
    return setmetatable({x = x, y = y, z = z, w = w}, quat_mt)
  end
end

function quat_mt:length()
  return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w)
end

function quat_mt:normalized()
  local len = self:length()
  if len < 1e-12 then return new_quat(0, 0, 0, 1) end
  return new_quat(self.x / len, self.y / len, self.z / len, self.w / len)
end

function quat_mt:inversed()
  -- For unit quaternions, inverse == conjugate
  local len_sq = self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w
  if len_sq < 1e-12 then return new_quat(0, 0, 0, 1) end
  return new_quat(-self.x / len_sq, -self.y / len_sq, -self.z / len_sq, self.w / len_sq)
end

-- Hamilton product: q1 * q2 composes rotations (apply q2 first, then q1)
local function quat_mul_quat(a, b)
  return new_quat(
    a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
  )
end

-- Rotate a vec3 by a quat: v' = q * v * q^-1
local function quat_mul_vec3(q, v)
  -- Optimized form: v' = v + 2*q_xyz × (q_xyz × v + q_w * v)
  local qx, qy, qz, qw = q.x, q.y, q.z, q.w
  local vx, vy, vz = v.x, v.y, v.z

  -- t = 2 * (q_xyz × v)
  local tx = 2 * (qy * vz - qz * vy)
  local ty = 2 * (qz * vx - qx * vz)
  local tz = 2 * (qx * vy - qy * vx)

  -- v' = v + q_w * t + q_xyz × t
  return new_vec3(
    vx + qw * tx + (qy * tz - qz * ty),
    vy + qw * ty + (qz * tx - qx * tz),
    vz + qw * tz + (qx * ty - qy * tx)
  )
end

quat_mt.__mul = function(a, b)
  if getmetatable(b) == vec3_mt then
    return quat_mul_vec3(a, b)
  elseif getmetatable(b) == quat_mt then
    return quat_mul_quat(a, b)
  else
    error("quat * unknown type")
  end
end

-- q1 / q2 = q1 * q2^-1 (relative rotation)
quat_mt.__div = function(a, b)
  return quat_mul_quat(a, b:inversed())
end

quat_mt.__tostring = function(q)
  return string.format("quat(%.4f, %.4f, %.4f, %.4f)", q.x, q.y, q.z, q.w)
end

M.quat = new_quat

-- Construct a quat from an axis (vec3, will be normalized) and angle (rad)
function M.quatFromAxisAngle(axis, angle)
  local ax = axis:normalized()
  local half = angle * 0.5
  local s = math.sin(half)
  return new_quat(ax.x * s, ax.y * s, ax.z * s, math.cos(half))
end

-- ============================================================
-- mat3 (used only for inertia tensors in cluster code)
-- ============================================================
local mat3_mt = {}
mat3_mt.__index = mat3_mt

-- Row-major storage. m[1..9]
local function new_mat3(m)
  local self = {}
  if m == nil then
    -- identity
    self.m = {1, 0, 0, 0, 1, 0, 0, 0, 1}
  else
    self.m = {m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]}
  end
  return setmetatable(self, mat3_mt)
end

function mat3_mt:get(r, c)
  return self.m[(r - 1) * 3 + c]
end

function mat3_mt:set(r, c, v)
  self.m[(r - 1) * 3 + c] = v
end

function mat3_mt:trace()
  return self.m[1] + self.m[5] + self.m[9]
end

function mat3_mt:transpose()
  return new_mat3({
    self.m[1], self.m[4], self.m[7],
    self.m[2], self.m[5], self.m[8],
    self.m[3], self.m[6], self.m[9],
  })
end

mat3_mt.__tostring = function(m)
  return string.format(
    "mat3[ %.3f %.3f %.3f ; %.3f %.3f %.3f ; %.3f %.3f %.3f ]",
    m.m[1], m.m[2], m.m[3], m.m[4], m.m[5], m.m[6], m.m[7], m.m[8], m.m[9]
  )
end

M.mat3 = new_mat3

-- ============================================================
-- Helper globals (BeamNG exposes these at global scope)
-- ============================================================
function M.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function M.lerp(a, b, t)
  if type(a) == "number" then
    return a + (b - a) * t
  else
    -- assume vec3
    return new_vec3(
      a.x + (b.x - a.x) * t,
      a.y + (b.y - a.y) * t,
      a.z + (b.z - a.z) * t
    )
  end
end

-- Install into the global environment so modules under test can
-- use them without importing explicitly.
function M.install_globals()
  _G.vec3 = M.vec3
  _G.quat = M.quat
  _G.mat3 = M.mat3
  _G.quatFromAxisAngle = M.quatFromAxisAngle
  _G.clamp = M.clamp
  _G.lerp = M.lerp
end

return M
