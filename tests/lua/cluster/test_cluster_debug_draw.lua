-- Sanity tests for the HSV→RGB and golden-angle color mapping in
-- cluster_debug_draw.lua. These are the only parts of the debug
-- module with testable math; the actual draw code touches
-- obj.debugDrawProxy and can only be validated visually in-game.
--
-- We need to stub `color()` and `float3()` to load the module
-- without BeamNG. drawCylinder/drawSphere never run during tests
-- because we only call hsv_to_rgb and cluster_color directly.

local T = {}

-- Minimal stubs needed just to load the module.
if not _G.color then
  _G.color = function(r, g, b, a) return {r = r, g = g, b = b, a = a} end
end
if not _G.float3 then
  _G.float3 = function(x, y, z) return {x = x, y = y, z = z} end
end

local debug_draw = require("cluster_debug_draw")

local function assert_near(a, e, tol, label)
  tol = tol or 1
  if math.abs(a - e) > tol then
    error(string.format("%s: expected %d, got %d", label or "value", e, a))
  end
end

-- ============================================================
-- hsv_to_rgb
-- ============================================================

function T.test_hsv_red()
  local r, g, b = debug_draw.hsv_to_rgb(0, 1, 1)
  assert_near(r, 255, 0, "red.r")
  assert_near(g, 0, 0, "red.g")
  assert_near(b, 0, 0, "red.b")
end

function T.test_hsv_green()
  local r, g, b = debug_draw.hsv_to_rgb(120, 1, 1)
  assert_near(r, 0, 0, "green.r")
  assert_near(g, 255, 0, "green.g")
  assert_near(b, 0, 0, "green.b")
end

function T.test_hsv_blue()
  local r, g, b = debug_draw.hsv_to_rgb(240, 1, 1)
  assert_near(r, 0, 0, "blue.r")
  assert_near(g, 0, 0, "blue.g")
  assert_near(b, 255, 0, "blue.b")
end

function T.test_hsv_cyan()
  local r, g, b = debug_draw.hsv_to_rgb(180, 1, 1)
  assert_near(r, 0, 0, "cyan.r")
  assert_near(g, 255, 0, "cyan.g")
  assert_near(b, 255, 0, "cyan.b")
end

function T.test_hsv_full_saturation_full_value_stays_in_range()
  -- Sweep hue in 10° steps; every output should be in [0, 255].
  for h = 0, 359, 10 do
    local r, g, b = debug_draw.hsv_to_rgb(h, 1, 1)
    assert(r >= 0 and r <= 255, "r out of range at h=" .. h)
    assert(g >= 0 and g <= 255, "g out of range at h=" .. h)
    assert(b >= 0 and b <= 255, "b out of range at h=" .. h)
  end
end

function T.test_hsv_zero_saturation_is_gray()
  -- At s=0, HSV should produce gray (r == g == b).
  local r, g, b = debug_draw.hsv_to_rgb(180, 0, 0.5)
  assert(r == g and g == b, "expected gray, got " .. r .. "," .. g .. "," .. b)
end

-- ============================================================
-- cluster_color (golden-angle)
-- ============================================================

function T.test_cluster_color_id_1_stable()
  local r1, g1, b1 = debug_draw.cluster_color(1)
  local r2, g2, b2 = debug_draw.cluster_color(1)
  assert(r1 == r2 and g1 == g2 and b1 == b2, "cluster_color(1) should be deterministic")
end

function T.test_cluster_colors_differ_across_ids()
  -- First few cluster ids should yield distinct colors.
  local colors = {}
  for i = 1, 5 do
    local r, g, b = debug_draw.cluster_color(i)
    table.insert(colors, {r, g, b})
  end
  -- Ensure no two are identical.
  for i = 1, #colors do
    for j = i + 1, #colors do
      local same = colors[i][1] == colors[j][1]
               and colors[i][2] == colors[j][2]
               and colors[i][3] == colors[j][3]
      assert(not same, string.format(
        "cluster_color(%d) == cluster_color(%d): %d,%d,%d",
        i, j, colors[i][1], colors[i][2], colors[i][3]))
    end
  end
end

function T.test_cluster_color_valid_range()
  for i = 1, 20 do
    local r, g, b = debug_draw.cluster_color(i)
    assert(r >= 0 and r <= 255)
    assert(g >= 0 and g <= 255)
    assert(b >= 0 and b <= 255)
  end
end

return T
