-- Sanity tests for the vec3/quat/mat3 stubs themselves.
-- If these fail, nothing else in the test suite can be trusted.

local T = {}

local function assert_near(actual, expected, tol, label)
  tol = tol or 1e-6
  if math.abs(actual - expected) > tol then
    error(string.format("%s: expected %.6f, got %.6f", label or "value", expected, actual))
  end
end

local function assert_vec_near(actual, expected, tol, label)
  tol = tol or 1e-6
  label = label or "vec"
  assert_near(actual.x, expected.x, tol, label .. ".x")
  assert_near(actual.y, expected.y, tol, label .. ".y")
  assert_near(actual.z, expected.z, tol, label .. ".z")
end

-- ============================================================
-- vec3
-- ============================================================
function T.test_vec3_ctor()
  local v = vec3(1, 2, 3)
  assert_near(v.x, 1, nil, "v.x")
  assert_near(v.y, 2, nil, "v.y")
  assert_near(v.z, 3, nil, "v.z")
end

function T.test_vec3_default_zero()
  local v = vec3()
  assert_near(v.x, 0); assert_near(v.y, 0); assert_near(v.z, 0)
end

function T.test_vec3_from_table()
  local v1 = vec3(vec3(4, 5, 6))
  assert_near(v1.x, 4); assert_near(v1.y, 5); assert_near(v1.z, 6)
end

function T.test_vec3_add()
  assert_vec_near(vec3(1, 2, 3) + vec3(4, 5, 6), vec3(5, 7, 9))
end

function T.test_vec3_sub()
  assert_vec_near(vec3(5, 5, 5) - vec3(1, 2, 3), vec3(4, 3, 2))
end

function T.test_vec3_scalar_mul()
  assert_vec_near(vec3(1, 2, 3) * 2, vec3(2, 4, 6))
  assert_vec_near(2 * vec3(1, 2, 3), vec3(2, 4, 6))
end

function T.test_vec3_length()
  assert_near(vec3(3, 4, 0):length(), 5, nil, "length")
  assert_near(vec3(0, 0, 0):length(), 0, nil, "zero length")
end

function T.test_vec3_normalized()
  local n = vec3(3, 4, 0):normalized()
  assert_near(n:length(), 1, 1e-9, "normalized length")
  assert_near(n.x, 0.6, 1e-9, "nx")
  assert_near(n.y, 0.8, 1e-9, "ny")
end

function T.test_vec3_dot()
  assert_near(vec3(1, 2, 3):dot(vec3(4, 5, 6)), 32, nil, "dot")
  assert_near(vec3(1, 0, 0):dot(vec3(0, 1, 0)), 0, nil, "orthogonal dot")
end

function T.test_vec3_cross_basis()
  -- Right-hand rule: x × y = z
  assert_vec_near(vec3(1, 0, 0):cross(vec3(0, 1, 0)), vec3(0, 0, 1), nil, "x cross y")
  assert_vec_near(vec3(0, 1, 0):cross(vec3(0, 0, 1)), vec3(1, 0, 0), nil, "y cross z")
  assert_vec_near(vec3(0, 0, 1):cross(vec3(1, 0, 0)), vec3(0, 1, 0), nil, "z cross x")
end

function T.test_vec3_distance()
  assert_near(vec3(0, 0, 0):distance(vec3(3, 4, 0)), 5, nil, "distance")
end

-- ============================================================
-- quat
-- ============================================================
function T.test_quat_identity_rotates_nothing()
  local q = quat(0, 0, 0, 1)  -- identity
  local v = vec3(1, 2, 3)
  assert_vec_near(q * v, v, nil, "identity rotation")
end

function T.test_quat_90_around_z_maps_x_to_y()
  -- Rotation by π/2 around +Z: (0, 0, sin(π/4), cos(π/4))
  local q = quat(0, 0, math.sin(math.pi / 4), math.cos(math.pi / 4))
  local r = q * vec3(1, 0, 0)
  assert_vec_near(r, vec3(0, 1, 0), 1e-9, "z90(x)")
end

function T.test_quat_90_around_x_maps_y_to_z()
  local q = quat(math.sin(math.pi / 4), 0, 0, math.cos(math.pi / 4))
  local r = q * vec3(0, 1, 0)
  assert_vec_near(r, vec3(0, 0, 1), 1e-9, "x90(y)")
end

function T.test_quat_90_around_y_maps_z_to_x()
  local q = quat(0, math.sin(math.pi / 4), 0, math.cos(math.pi / 4))
  local r = q * vec3(0, 0, 1)
  assert_vec_near(r, vec3(1, 0, 0), 1e-9, "y90(z)")
end

function T.test_quat_from_axis_angle_180_around_x()
  -- Rotate (0, 1, 0) by 180° around +X should give (0, -1, 0)
  local q = quatFromAxisAngle(vec3(1, 0, 0), math.pi)
  local r = q * vec3(0, 1, 0)
  assert_vec_near(r, vec3(0, -1, 0), 1e-9, "180x(y)")
end

function T.test_quat_compose_and_inverse()
  -- q * q^-1 = identity. Applying the product to any vec should return the vec.
  local q = quatFromAxisAngle(vec3(1, 1, 1), math.pi / 3)
  local q_inv = q:inversed()
  local identity = q * q_inv
  local v = vec3(2, -1, 3)
  assert_vec_near(identity * v, v, 1e-9, "q*q^-1 identity")
end

function T.test_quat_compose_associative_ordering()
  -- (q1 * q2) * v should equal q1 * (q2 * v)
  local q1 = quatFromAxisAngle(vec3(1, 0, 0), math.pi / 4)
  local q2 = quatFromAxisAngle(vec3(0, 1, 0), math.pi / 3)
  local v = vec3(1, 2, 3)
  local composed = (q1 * q2) * v
  local sequential = q1 * (q2 * v)
  assert_vec_near(composed, sequential, 1e-9, "rotation compose")
end

-- ============================================================
-- mat3
-- ============================================================
function T.test_mat3_identity_default()
  local m = mat3()
  assert_near(m:get(1, 1), 1, nil, "m[1][1]")
  assert_near(m:get(2, 2), 1, nil, "m[2][2]")
  assert_near(m:get(3, 3), 1, nil, "m[3][3]")
  assert_near(m:get(1, 2), 0, nil, "m[1][2]")
  assert_near(m:trace(), 3, nil, "identity trace")
end

function T.test_mat3_transpose()
  local m = mat3({1, 2, 3, 4, 5, 6, 7, 8, 9})
  local t = m:transpose()
  assert_near(t:get(1, 1), 1)
  assert_near(t:get(1, 2), 4)
  assert_near(t:get(1, 3), 7)
  assert_near(t:get(2, 1), 2)
  assert_near(t:get(3, 3), 9)
end

-- ============================================================
-- helpers
-- ============================================================
function T.test_clamp()
  assert_near(clamp(5, 0, 10), 5)
  assert_near(clamp(-1, 0, 10), 0)
  assert_near(clamp(11, 0, 10), 10)
end

function T.test_lerp_scalar()
  assert_near(lerp(0, 10, 0.5), 5)
  assert_near(lerp(0, 10, 0), 0)
  assert_near(lerp(0, 10, 1), 10)
end

function T.test_lerp_vec3()
  assert_vec_near(lerp(vec3(0, 0, 0), vec3(2, 4, 6), 0.5), vec3(1, 2, 3))
end

return T
