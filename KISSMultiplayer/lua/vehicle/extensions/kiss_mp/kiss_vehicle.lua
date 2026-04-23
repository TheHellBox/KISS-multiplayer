local M = {}
local parts_config = v.config
local nodes = {}
local node_by_cid = {}
local wheel_related_cids = {}
local boundary_cids = {}
local wheel_side_cids = {}
local non_core_cids = {}
local layer1_core_cids = {}
local layer1_observation_cids = {}
local layer1_actuation_cids = {}
local full_neighbors = {}
local layer1_components = {}
local layer1_frame_refnode_states = {}
local layer1_actuator_states = {}
local layer1_support_pair_centers = {}
local layer1_actuator_force_factor = 0

local last_node = 1
local nodes_per_frame = 32

local node_pos_thresh = 3
local node_pos_thresh_sqr = node_pos_thresh * node_pos_thresh

M.layer1_enabled = true
M.layer1_centroid_body = vec3(0, 0, 0)
M.layer1_included_count = 0
M.layer1_excluded_count = 0
M.layer1_boundary_count = 0
M.layer1_wheel_side_count = 0
M.layer1_non_core_count = 0
M.layer1_observation_count = 0
M.layer1_actuation_count = 0
M.layer1_body_length = 0
M.layer1_body_width = 0
M.layer1_body_height = 0
M.layer1_geometry_mode = "degraded_fallback"
M.layer1_frame_planar_gain = 1.5
M.layer1_frame_yaw_gain = 1.75
M.layer1_frame_yaw_rate_gain = 1.75
M.layer1_support_gain = 0.35
M.layer1_frame_planar_max_dv = 12.0
M.layer1_frame_yaw_max_dv = 12.0
M.layer1_shell_inset_cm = 8.0
M.layer1_debug_viz = false

M.test_quat = quat(0.707, 0, 0, 0.707)

local function get_rest_body(node, inverse_rot)
  local p = node.pos
  if p and (p.x ~= nil or p[1] ~= nil) then
    return vec3(
      p.x or p[1],
      p.y or p[2],
      p.z or p[3]
    )
  end
  return inverse_rot * obj:getNodePosition(node.cid)
end

local function is_integer(n)
  return type(n) == "number" and n == math.floor(n)
end

local function key_looks_nodeish(key)
  if type(key) ~= "string" then return false end
  local lower = key:lower()
  return lower:find("node", 1, true) ~= nil
    or lower:find("cid", 1, true) ~= nil
    or lower:find("hub", 1, true) ~= nil
    or lower:find("spindle", 1, true) ~= nil
    or lower:find("axle", 1, true) ~= nil
    or lower:find("brake", 1, true) ~= nil
    or lower:find("susp", 1, true) ~= nil
    or lower:find("arm", 1, true) ~= nil
end

local function count_set(set_like)
  local count = 0
  for _ in pairs(set_like or {}) do
    count = count + 1
  end
  return count
end

local function add_valid_cid(out, cid, valid_cids)
  if valid_cids[cid] then
    out[cid] = true
  end
end

local function resolve_controller_cid(value, valid_cids)
  if type(value) == "number" then
    return valid_cids[value] and value or nil
  end
  if type(value) == "string" and beamstate and beamstate.nodeNameMap then
    local mapped = beamstate.nodeNameMap[value]
    return valid_cids[mapped] and mapped or nil
  end
  return nil
end

local function resolve_node_cid(value, valid_cids)
  if type(value) == "number" then
    return valid_cids[value] and value or nil
  end
  if type(value) == "string" then
    local numeric = tonumber(value)
    if numeric and valid_cids[numeric] then
      return numeric
    end
    if beamstate and beamstate.nodeNameMap then
      local mapped = beamstate.nodeNameMap[value]
      return valid_cids[mapped] and mapped or nil
    end
  end
  return nil
end

local function extract_strict_frame_refnode_cids(valid_cids)
  local refs = v.data.refNodes
  if type(refs) ~= "table" then
    return {}
  end

  local function ordered_unique(ref_value, back_value, up_value)
    local out = {}
    local seen = {}
    for _, value in ipairs({ref_value, back_value, up_value}) do
      local cid = resolve_node_cid(value, valid_cids)
      if cid and not seen[cid] then
        seen[cid] = true
        out[#out + 1] = cid
      end
    end
    return out
  end

  local direct = ordered_unique(
    refs.ref or refs.idRef or refs.cidRef,
    refs.back or refs.idX or refs.cidX,
    refs.up or refs.idY or refs.cidY
  )
  if #direct == 3 then
    return direct
  end

  local best = direct
  for _, entry in pairs(refs) do
    if type(entry) == "table" then
      local candidate = ordered_unique(
        entry.ref or entry.idRef or entry.cidRef,
        entry.back or entry.idX or entry.cidX,
        entry.up or entry.idY or entry.cidY
      )
      if #candidate == 3 then
        return candidate
      end
      if #candidate > #best then
        best = candidate
      end
    end
  end

  return best
end

local function build_layer1_frame_refnodes(valid_cids)
  layer1_frame_refnode_states = {}

  local frame_cids = extract_strict_frame_refnode_cids(valid_cids)
  for _, cid in ipairs(frame_cids) do
    local state = node_by_cid[cid]
    if state and not wheel_related_cids[cid] and not boundary_cids[cid] then
      layer1_frame_refnode_states[#layer1_frame_refnode_states + 1] = state
    end
  end
end

local function build_mirrored_actuator_pairs()
  local frame_refnode_cids = {}
  for _, state in ipairs(layer1_frame_refnode_states) do
    frame_refnode_cids[state.cid] = true
  end

  local eligible = {}
  local max_abs_x = 0
  local max_y = -math.huge
  local min_y = math.huge
  local min_z = math.huge
  local max_z = -math.huge

  for _, node in ipairs(nodes) do
    if layer1_core_cids[node.cid]
        and not boundary_cids[node.cid]
        and not wheel_related_cids[node.cid]
        and not frame_refnode_cids[node.cid] then
      local rb = node.rest_body
      eligible[#eligible + 1] = node
      max_abs_x = math.max(max_abs_x, math.abs(rb.x))
      max_y = math.max(max_y, rb.y)
      min_y = math.min(min_y, rb.y)
      min_z = math.min(min_z, rb.z)
      max_z = math.max(max_z, rb.z)
    end
  end

  local function collect_candidate_sides(prefer_inner, use_inset)
    local left_nodes = {}
    local right_nodes = {}
    local inner_x_limit = math.max(0.35, max_abs_x * 0.7)
    local low_z_limit = min_z + ((max_z - min_z) * 0.65)
    local inset_m = math.max(0, (M.layer1_shell_inset_cm or 0) * 0.01)
    local lateral_limit = math.max(0.15, max_abs_x - inset_m)
    local front_limit = max_y - inset_m
    local rear_limit = min_y + inset_m

    for _, node in ipairs(eligible) do
      local rb = node.rest_body
      local abs_x = math.abs(rb.x)
      local passes_inset = (not use_inset)
        or (abs_x <= lateral_limit and rb.y <= front_limit and rb.y >= rear_limit)
      local passes_inner = (abs_x >= 0.15 and abs_x <= inner_x_limit and rb.z <= low_z_limit)
      if passes_inset and ((not prefer_inner) or passes_inner) then
        if rb.x <= -0.15 then
          left_nodes[#left_nodes + 1] = node
        elseif rb.x >= 0.15 then
          right_nodes[#right_nodes + 1] = node
        end
      end
    end

    table.sort(left_nodes, function(a, b) return a.rest_body.y > b.rest_body.y end)
    table.sort(right_nodes, function(a, b) return a.rest_body.y > b.rest_body.y end)
    return left_nodes, right_nodes
  end

  local function build_pairs_from_sides(left_nodes, right_nodes)
    local used_right = {}
    local pairs = {}
    for _, left in ipairs(left_nodes) do
      local best_index = nil
      local best_score = nil
      local lx, ly, lz = left.rest_body.x, left.rest_body.y, left.rest_body.z

      for idx, right in ipairs(right_nodes) do
        if not used_right[idx] then
          local rx, ry, rz = right.rest_body.x, right.rest_body.y, right.rest_body.z
          local x_sym = math.abs(math.abs(lx) - math.abs(rx))
          local y_diff = math.abs(ly - ry)
          local z_diff = math.abs(lz - rz)
          if x_sym <= 0.75 and y_diff <= 1.5 and z_diff <= 0.75 then
            local avg_abs_x = (math.abs(lx) + math.abs(rx)) * 0.5
            local avg_z = (lz + rz) * 0.5
            local z_norm = (max_z > min_z) and ((avg_z - min_z) / (max_z - min_z)) or 0
            local score = (x_sym * 4) + y_diff + (z_diff * 2) + (avg_abs_x * 2.5) + (z_norm * 2)
            if not best_score or score < best_score then
              best_score = score
              best_index = idx
            end
          end
        end
      end

      if best_index then
        used_right[best_index] = true
        local right = right_nodes[best_index]
        pairs[#pairs + 1] = {
          left = left,
          right = right,
          center_y = (left.rest_body.y + right.rest_body.y) * 0.5,
          structure_score = best_score or 0,
        }
      end
    end
    table.sort(pairs, function(a, b) return a.center_y > b.center_y end)
    return pairs
  end

  local use_inset = (M.layer1_shell_inset_cm or 0) > 0
  local left_nodes, right_nodes = collect_candidate_sides(true, use_inset)
  local pairs = build_pairs_from_sides(left_nodes, right_nodes)
  if #pairs < 2 then
    left_nodes, right_nodes = collect_candidate_sides(true, false)
    pairs = build_pairs_from_sides(left_nodes, right_nodes)
  end
  if #pairs < 2 then
    left_nodes, right_nodes = collect_candidate_sides(false, use_inset)
    pairs = build_pairs_from_sides(left_nodes, right_nodes)
  end
  if #pairs < 2 then
    left_nodes, right_nodes = collect_candidate_sides(false, false)
    pairs = build_pairs_from_sides(left_nodes, right_nodes)
  end
  return pairs
end

local function build_mirrored_actuator_states()
  local pairs = build_mirrored_actuator_pairs()
  if #pairs < 2 then
    return false
  end

  local max_y = pairs[1].center_y
  local min_y = pairs[#pairs].center_y
  local span = math.max(0.001, max_y - min_y)

  local function choose_edge_pair(from_front)
    local best = nil
    local best_score = nil
    local edge_y = from_front and max_y or min_y
    local band_threshold = from_front and (max_y - span * 0.35) or (min_y + span * 0.35)

    for _, pair in ipairs(pairs) do
      local in_band = from_front and (pair.center_y >= band_threshold) or (pair.center_y <= band_threshold)
      if in_band then
        local edge_penalty = math.abs(edge_y - pair.center_y)
        local score = pair.structure_score + edge_penalty
        if not best_score or score < best_score then
          best_score = score
          best = pair
        end
      end
    end

    return best or (from_front and pairs[1] or pairs[#pairs])
  end

  local selected_pairs = {}
  local front_pair = choose_edge_pair(true)
  local rear_pair = choose_edge_pair(false)
  selected_pairs[#selected_pairs + 1] = front_pair
  if rear_pair ~= front_pair then
    selected_pairs[#selected_pairs + 1] = rear_pair
  end

  local longitudinal_span = math.abs(front_pair.center_y - rear_pair.center_y)
  if longitudinal_span > 4.0 and #pairs >= 3 then
    local mid_target = (front_pair.center_y + rear_pair.center_y) * 0.5
    local best_mid = nil
    local best_mid_score = nil
    for idx = 2, #pairs - 1 do
      local pair = pairs[idx]
      local score = math.abs(pair.center_y - mid_target) + pair.structure_score
      if not best_mid_score or score < best_mid_score then
        best_mid_score = score
        best_mid = pair
      end
    end
    if best_mid then
      selected_pairs[#selected_pairs + 1] = best_mid
    end
  end

  layer1_actuator_states = {}
  layer1_actuation_cids = {}
  layer1_support_pair_centers = {}
  layer1_actuator_force_factor = 0

  local factor_sum = 0
  local factor_count = 0
  for _, pair in ipairs(selected_pairs) do
    layer1_support_pair_centers[#layer1_support_pair_centers + 1] = vec3(
      0,
      (pair.left.rest_body.y + pair.right.rest_body.y) * 0.5,
      (pair.left.rest_body.z + pair.right.rest_body.z) * 0.5
    )
    for _, state in ipairs({pair.left, pair.right}) do
      if not layer1_actuation_cids[state.cid] then
        layer1_actuation_cids[state.cid] = true
        layer1_actuator_states[#layer1_actuator_states + 1] = state
        factor_sum = factor_sum + state.factor
        factor_count = factor_count + 1
      end
    end
  end

  layer1_actuator_force_factor = factor_count > 0 and (factor_sum / factor_count) or 0
  M.layer1_geometry_mode = (#selected_pairs >= 3) and "mirrored_pairs_long_vehicle" or "mirrored_pairs"
  return #layer1_actuator_states >= 4
end

local function build_layer1_actuators(valid_cids)
  layer1_actuator_states = {}
  layer1_actuation_cids = {}
  layer1_support_pair_centers = {}
  layer1_actuator_force_factor = 0

  build_layer1_frame_refnodes(valid_cids)

  if build_mirrored_actuator_states() then
    return
  end

  local factor_sum = 0
  local factor_count = 0
  for _, state in ipairs(layer1_frame_refnode_states) do
    layer1_actuation_cids[state.cid] = true
    layer1_actuator_states[#layer1_actuator_states + 1] = state
    factor_sum = factor_sum + state.factor
    factor_count = factor_count + 1
  end
  if #layer1_actuator_states >= 3 then
    layer1_actuator_force_factor = factor_sum / factor_count
    M.layer1_geometry_mode = "strict_refnode_only"
    return
  end

  for _, node in ipairs(nodes) do
    if layer1_core_cids[node.cid] and not layer1_actuation_cids[node.cid] then
      layer1_actuation_cids[node.cid] = true
      layer1_actuator_states[#layer1_actuator_states + 1] = node
      factor_sum = factor_sum + node.factor
      factor_count = factor_count + 1
      if #layer1_actuator_states >= 3 then
        break
      end
    end
  end

  layer1_actuator_force_factor = factor_count > 0 and (factor_sum / factor_count) or 0
  M.layer1_geometry_mode = "degraded_fallback"
end

local function rebuild_layer1_actuators()
  local valid_cids = {}
  for cid in pairs(node_by_cid) do
    valid_cids[cid] = true
  end
  build_layer1_actuators(valid_cids)
  build_layer1_centroid()
end

local function collect_wheel_cids(value, valid_cids, out, key_hint)
  local value_type = type(value)
  if value_type == "table" then
    for child_key, child_value in pairs(value) do
      local next_hint = key_looks_nodeish(child_key) and child_key or key_hint
      collect_wheel_cids(child_value, valid_cids, out, next_hint)
    end
  elseif key_looks_nodeish(key_hint) and is_integer(value) and valid_cids[value] then
    out[value] = true
  end
end

local function extract_boundary_cids(valid_cids)
  local out = {}

  if v.data.nodes then
    for _, node in pairs(v.data.nodes) do
      if type(node) == "table" and node.couplerTag and node.couplerTag ~= "" and node.cid then
        add_valid_cid(out, node.cid, valid_cids)
      end
    end
  end

  if v.data.hydros then
    for _, hydro in pairs(v.data.hydros) do
      if type(hydro) == "table" then
        add_valid_cid(out, hydro.id1 or hydro.cid1, valid_cids)
        add_valid_cid(out, hydro.id2 or hydro.cid2, valid_cids)
      end
    end
  end

  if v.data.slidenodes then
    for _, slidenode in pairs(v.data.slidenodes) do
      if type(slidenode) == "table" then
        add_valid_cid(out, slidenode.id1 or slidenode.cid, valid_cids)
        add_valid_cid(out, slidenode.id2, valid_cids)
        if type(slidenode.nodes) == "table" then
          for _, cid in pairs(slidenode.nodes) do
            add_valid_cid(out, cid, valid_cids)
          end
        end
      end
    end
  end

  if type(v.data.controller) == "table" then
    for _, controller in pairs(v.data.controller) do
      if type(controller) == "table"
          and controller.fileName == "advancedCouplerControl"
          and type(controller.couplerNodes) == "table" then
        for _, entry in pairs(controller.couplerNodes) do
          if type(entry) == "table" then
            add_valid_cid(out, resolve_controller_cid(entry.cid1 or entry.id1, valid_cids), valid_cids)
            add_valid_cid(out, resolve_controller_cid(entry.cid2 or entry.id2, valid_cids), valid_cids)
          end
        end
      end
    end
  end

  return out
end

local function build_component_sets(valid_cids)
  boundary_cids = extract_boundary_cids(valid_cids)
  wheel_side_cids = {}
  non_core_cids = {}
  layer1_core_cids = {}
  layer1_observation_cids = {}
  layer1_components = {}
  full_neighbors = {}

  local core_nodes = {}
  local wheel_nodes = {}
  local boundary_nodes = {}

  for cid in pairs(valid_cids) do
    if boundary_cids[cid] then
      boundary_nodes[#boundary_nodes + 1] = cid
    elseif wheel_related_cids[cid] then
      wheel_side_cids[cid] = true
      non_core_cids[cid] = true
      wheel_nodes[#wheel_nodes + 1] = cid
    else
      layer1_core_cids[cid] = true
      layer1_observation_cids[cid] = true
      core_nodes[#core_nodes + 1] = cid
    end
  end

  if next(layer1_observation_cids) == nil then
    for cid in pairs(valid_cids) do
      if not boundary_cids[cid] then
        layer1_core_cids[cid] = true
        layer1_observation_cids[cid] = true
        core_nodes[#core_nodes + 1] = cid
      end
    end
  end

  build_layer1_actuators(valid_cids)

  table.sort(core_nodes)
  table.sort(wheel_nodes)
  table.sort(boundary_nodes)

  if #core_nodes > 0 then
    layer1_components[#layer1_components + 1] = {
      nodes = core_nodes,
      kind = "core",
    }
  end
  if #wheel_nodes > 0 then
    layer1_components[#layer1_components + 1] = {
      nodes = wheel_nodes,
      kind = "wheel_side",
    }
  end
  if #boundary_nodes > 0 then
    layer1_components[#layer1_components + 1] = {
      nodes = boundary_nodes,
      kind = "boundary",
    }
  end
end

local function build_layer1_centroid()
  local sum_x, sum_y, sum_z, total_mass = 0, 0, 0, 0
  local count = 0

  for _, node in ipairs(nodes) do
    if layer1_observation_cids[node.cid] then
      sum_x = sum_x + node.rest_body.x * node.mass
      sum_y = sum_y + node.rest_body.y * node.mass
      sum_z = sum_z + node.rest_body.z * node.mass
      total_mass = total_mass + node.mass
      count = count + 1
    end
  end

  if count == 0 then
    for _, node in ipairs(nodes) do
      if layer1_core_cids[node.cid] then
        sum_x = sum_x + node.rest_body.x * node.mass
        sum_y = sum_y + node.rest_body.y * node.mass
        sum_z = sum_z + node.rest_body.z * node.mass
        total_mass = total_mass + node.mass
        count = count + 1
      end
    end
  end

  if count == 0 then
    for _, node in ipairs(nodes) do
      sum_x = sum_x + node.rest_body.x * node.mass
      sum_y = sum_y + node.rest_body.y * node.mass
      sum_z = sum_z + node.rest_body.z * node.mass
      total_mass = total_mass + node.mass
      count = count + 1
    end
  end

  local fallback_centroid = vec3(
    total_mass > 0 and (sum_x / total_mass) or 0,
    total_mass > 0 and (sum_y / total_mass) or 0,
    total_mass > 0 and (sum_z / total_mass) or 0
  )

  if not is_rigid_prop() then
    if #layer1_support_pair_centers >= 2 then
      local pair_sum_y, pair_sum_z = 0, 0
      for _, pair_center in ipairs(layer1_support_pair_centers) do
        pair_sum_y = pair_sum_y + pair_center.y
        pair_sum_z = pair_sum_z + pair_center.z
      end
      M.layer1_centroid_body = vec3(
        0,
        pair_sum_y / #layer1_support_pair_centers,
        pair_sum_z / #layer1_support_pair_centers
      )
    else
      M.layer1_centroid_body = vec3(0, fallback_centroid.y, fallback_centroid.z)
    end
  else
    M.layer1_centroid_body = fallback_centroid
  end

  M.layer1_included_count = count
  M.layer1_excluded_count = #nodes - count
  M.layer1_boundary_count = count_set(boundary_cids)
  M.layer1_wheel_side_count = count_set(wheel_side_cids)
  M.layer1_non_core_count = count_set(non_core_cids)
  M.layer1_observation_count = count_set(layer1_observation_cids)
  M.layer1_actuation_count = count_set(layer1_actuation_cids)
end

local function build_body_extents()
  local min_x, min_y, min_z = math.huge, math.huge, math.huge
  local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

  for _, node in ipairs(nodes) do
    local rb = node.rest_body
    min_x = math.min(min_x, rb.x)
    min_y = math.min(min_y, rb.y)
    min_z = math.min(min_z, rb.z)
    max_x = math.max(max_x, rb.x)
    max_y = math.max(max_y, rb.y)
    max_z = math.max(max_z, rb.z)
  end

  if #nodes > 0 then
    M.layer1_body_width = max_x - min_x
    M.layer1_body_length = max_y - min_y
    M.layer1_body_height = max_z - min_z
  else
    M.layer1_body_width = 0
    M.layer1_body_length = 0
    M.layer1_body_height = 0
  end
end

local function onExtensionLoaded()
  nodes = {}
  node_by_cid = {}
  wheel_related_cids = {}
  boundary_cids = {}
  wheel_side_cids = {}
  non_core_cids = {}
  layer1_core_cids = {}
  layer1_observation_cids = {}
  layer1_actuation_cids = {}
  full_neighbors = {}
  layer1_components = {}
  layer1_frame_refnode_states = {}
  layer1_actuator_states = {}
  layer1_support_pair_centers = {}
  layer1_actuator_force_factor = 0
  last_node = 1
  M.layer1_enabled = true
  M.layer1_centroid_body = vec3(0, 0, 0)
  M.layer1_included_count = 0
  M.layer1_excluded_count = 0
  M.layer1_boundary_count = 0
  M.layer1_wheel_side_count = 0
  M.layer1_non_core_count = 0
  M.layer1_observation_count = 0
  M.layer1_actuation_count = 0
  M.layer1_body_length = 0
  M.layer1_body_width = 0
  M.layer1_body_height = 0
  M.layer1_geometry_mode = "degraded_fallback"

  local physics_fps = obj:getPhysicsFPS()
  local inverse_rot = quat(obj:getRotation()):inversed()
  local valid_cids = {}
  for _, node in pairs(v.data.nodes) do
    valid_cids[node.cid] = true
  end

  for _, node in pairs(v.data.nodes) do
    local node_mass = obj:getNodeMass(node.cid)
    local state = {
      cid = node.cid,
      mass = node_mass,
      factor = node_mass * physics_fps,
      active = true,
      rest_body = get_rest_body(node, inverse_rot),
    }
    nodes[#nodes + 1] = state
    node_by_cid[node.cid] = state
  end

  if type(v.data.wheels) == "table" then
    collect_wheel_cids(v.data.wheels, valid_cids, wheel_related_cids, nil)
  end

  build_component_sets(valid_cids)
  build_layer1_centroid()
  build_body_extents()
end

local function get_layer1_centroid_body()
  return M.layer1_centroid_body or vec3(0, 0, 0)
end

local function get_boundary_cids()
  return boundary_cids
end

local function get_wheel_side_cids()
  return wheel_side_cids
end

local function get_non_core_cids()
  return non_core_cids
end

local function get_layer1_core_cids()
  return layer1_core_cids
end

local function get_layer1_observation_cids()
  return layer1_observation_cids
end

local function get_layer1_actuation_cids()
  return layer1_actuation_cids
end

local function get_layer1_components()
  return layer1_components
end

local function get_layer1_frame_refnode_cids()
  local out = {}
  for _, state in ipairs(layer1_frame_refnode_states) do
    out[#out + 1] = state.cid
  end
  return out
end

local function get_layer1_geometry_mode()
  return M.layer1_geometry_mode or "degraded_fallback"
end

local function set_controller_tuning(frame_planar_gain, frame_yaw_gain, frame_yaw_rate_gain,
                                     support_gain, frame_planar_max_dv, frame_yaw_max_dv)
  if frame_planar_gain ~= nil then
    M.layer1_frame_planar_gain = math.max(0, frame_planar_gain)
  end
  if frame_yaw_gain ~= nil then
    M.layer1_frame_yaw_gain = math.max(0, frame_yaw_gain)
  end
  if frame_yaw_rate_gain ~= nil then
    M.layer1_frame_yaw_rate_gain = math.max(0, frame_yaw_rate_gain)
  end
  if support_gain ~= nil then
    M.layer1_support_gain = math.max(0, support_gain)
  end
  if frame_planar_max_dv ~= nil then
    M.layer1_frame_planar_max_dv = math.max(0.001, frame_planar_max_dv)
  end
  if frame_yaw_max_dv ~= nil then
    M.layer1_frame_yaw_max_dv = math.max(0.001, frame_yaw_max_dv)
  end
end

local function set_geometry_tuning(shell_inset_cm, debug_viz)
  local should_rebuild = false
  if shell_inset_cm ~= nil then
    local clamped = math.max(0, shell_inset_cm)
    should_rebuild = math.abs(clamped - (M.layer1_shell_inset_cm or 0)) > 0.001
    M.layer1_shell_inset_cm = clamped
  end
  if debug_viz ~= nil then
    M.layer1_debug_viz = debug_viz and true or false
  end
  if should_rebuild and next(node_by_cid) ~= nil then
    rebuild_layer1_actuators()
  end
end

local function get_layer1_stats()
  return {
    included = M.layer1_included_count or 0,
    excluded = M.layer1_excluded_count or 0,
    boundary = M.layer1_boundary_count or 0,
    wheel_side = M.layer1_wheel_side_count or 0,
    non_core = M.layer1_non_core_count or 0,
    observation = M.layer1_observation_count or 0,
    actuation = M.layer1_actuation_count or 0,
  }
end

local function draw_layer1_debug()
  if not M.layer1_debug_viz then return end

  local function draw_marker_post(world_pos, radius, height, marker_color, label, label_color)
    obj.debugDrawProxy:drawSphere(radius, world_pos:toFloat3(), marker_color)
    local top_pos = world_pos + vec3(0, 0, height)
    obj.debugDrawProxy:drawSphere(radius * 0.9, top_pos:toFloat3(), marker_color)
    obj.debugDrawProxy:drawText(label, top_pos:toFloat3(), label_color)
  end

  local vehicle_pos = vec3(obj:getPosition())
  local centroid_pos = vehicle_pos + quat(obj:getRotation()) * get_layer1_centroid_body()
  draw_marker_post(
    centroid_pos,
    0.12,
    3.0,
    color(0, 200, 255, 140),
    "L1 "..tostring(M.layer1_geometry_mode),
    color(255, 255, 255, 255)
  )

  for _, state in ipairs(layer1_frame_refnode_states) do
    local world_pos = vehicle_pos + obj:getNodePosition(state.cid)
    draw_marker_post(
      world_pos,
      0.09,
      3.0,
      color(0, 255, 0, 180),
      "F "..tostring(state.cid),
      color(0, 255, 0, 255)
    )
  end

  for _, state in ipairs(layer1_actuator_states) do
    local is_frame = false
    for _, frame_state in ipairs(layer1_frame_refnode_states) do
      if frame_state.cid == state.cid then
        is_frame = true
        break
      end
    end
    if not is_frame then
      local world_pos = vehicle_pos + obj:getNodePosition(state.cid)
      draw_marker_post(
        world_pos,
        0.08,
        3.0,
        color(255, 180, 0, 180),
        "S "..tostring(state.cid),
        color(255, 180, 0, 255)
      )
    end
  end
end

  -- NOTE:
  -- This is a temperary solution. It's not great. We made it to release the mod.
  -- A better solution will be used in future versions
local function update_eligible_nodes()
  local inverse_rot = quat(obj:getRotation()):inversed()
  for k = last_node, math.min(#nodes, last_node + nodes_per_frame) do
    local node = nodes[k]
    local local_node_pos = inverse_rot * obj:getNodePosition(node.cid)
    node.active = (local_node_pos - node.rest_body):squaredLength() < node_pos_thresh_sqr
    last_node = k
  end
  if last_node == #nodes then last_node = 1 end
end

local function get_body_gyro_local_omega()
  return vec3(
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity(),
    obj:getYawAngularVelocity()
  )
end

local function is_rigid_prop()
  return not (type(v.data.wheels) == "table" and next(v.data.wheels) ~= nil)
end

local function update_transform_info(we_own_this_vehicle)
  local r = quat(obj:getRotation())
  local p = obj:getPosition()
  local v_world = obj:getVelocity()
  local omega_local = get_body_gyro_local_omega()

  local throttle_input = electrics.values.throttle_input or 0
  local brake_input = electrics.values.brake_input or 0
  if electrics.values.gearboxMode == "arcade" and electrics.values.gearIndex < 0 then
    throttle_input, brake_input = brake_input, throttle_input
  end

  local input = {
    vehicle_id = obj:getID() or 0,
    throttle_input = throttle_input,
    brake_input = brake_input,
    clutch = electrics.values.clutch_input or 0,
    parkingbrake = electrics.values.parkingbrake_input or 0,
    steering_input = electrics.values.steering_input or 0,
  }
  local gearbox = kiss_gearbox.get_gearbox_data()
  local transform = {
    position = {p.x, p.y, p.z},
    rotation = {r.x, r.y, r.z, r.w},
    velocity = {v_world.x, v_world.y, v_world.z},
    angular_velocity = {omega_local.x, omega_local.y, omega_local.z},
    input = input,
    gearbox = gearbox,
  }
  obj:queueGameEngineLua("kisstransform.push_transform("..obj:getID()..", " .. string.format("%q", jsonEncode(transform)) .. ")")
end

local function apply_linear_velocity(x, y, z)
  local velocity = vec3(x, y, z)
  local force = float3(0, 0, 0)
  for k = 1, #nodes do
    local node = nodes[k]
    if node.active then
      local result = velocity * node.factor
      force:set(result.x, result.y, result.z)
      obj:applyForceVector(node.cid, force)
    end
  end
end

local function average_factor(states)
  local factor_sum = 0
  local count = 0
  for _, state in ipairs(states or {}) do
    factor_sum = factor_sum + state.factor
    count = count + 1
  end
  return count > 0 and (factor_sum / count) or 1
end

local function wrap_angle_pi(angle)
  while angle > math.pi do
    angle = angle - (math.pi * 2)
  end
  while angle < -math.pi do
    angle = angle + (math.pi * 2)
  end
  return angle
end

local function apply_rigid_pull_to_states(states, force_factor,
                                          current_centroid_offset, ccx, ccy, ccz, centroid_body,
                                          cluster_pos, cluster_rot, cluster_linvel, cluster_angvel_world,
                                          exclude, pull_gain, dp_deadband_sq, dv_deadband_sq, max_dv, max_dv_sq,
                                          planar_only)
  if #states == 0 then return end

  local cpx, cpy, cpz = cluster_pos.x, cluster_pos.y, cluster_pos.z
  local lvx, lvy, lvz = cluster_linvel.x, cluster_linvel.y, cluster_linvel.z
  local ax, ay, az = cluster_angvel_world.x, cluster_angvel_world.y, cluster_angvel_world.z
  local force = float3(0, 0, 0)

  for k = 1, #states do
    local node = states[k]
    if node.active then
      local cid = node.cid
      if not exclude[cid] and not exclude[tostring(cid)] then
        local rest_body = node.rest_body - centroid_body

        local target_offset = cluster_rot * rest_body
        local cur_offset = obj:getNodePosition(cid)
        local cur_rel_x = cur_offset.x - current_centroid_offset.x
        local cur_rel_y = cur_offset.y - current_centroid_offset.y
        local cur_rel_z = cur_offset.z - current_centroid_offset.z
        local tx = cpx + target_offset.x
        local ty = cpy + target_offset.y
        local tz = cpz + target_offset.z
        local cx = ccx + cur_rel_x
        local cy = ccy + cur_rel_y
        local cz = ccz + cur_rel_z
        local dp_x = tx - cx
        local dp_y = ty - cy
        local dp_z = tz - cz

        local rv_x = lvx + ay * cur_rel_z - az * cur_rel_y
        local rv_y = lvy + az * cur_rel_x - ax * cur_rel_z
        local rv_z = lvz + ax * cur_rel_y - ay * cur_rel_x

        if planar_only then
          dp_z = 0
          rv_z = 0
        end

        local vd_x = rv_x + pull_gain * dp_x
        local vd_y = rv_y + pull_gain * dp_y
        local vd_z = planar_only and 0 or (rv_z + pull_gain * dp_z)

        local vc = obj:getNodeVelocityVector(cid)
        local dv_x = vd_x - vc.x
        local dv_y = vd_y - vc.y
        local dv_z = vd_z - vc.z

        local dp_sq = dp_x * dp_x + dp_y * dp_y + dp_z * dp_z
        local dv_sq = dv_x * dv_x + dv_y * dv_y + dv_z * dv_z
        if dp_sq >= dp_deadband_sq or dv_sq >= dv_deadband_sq then
          if dv_sq > max_dv_sq then
            local scale = max_dv / math.sqrt(dv_sq)
            dv_x = dv_x * scale
            dv_y = dv_y * scale
            dv_z = dv_z * scale
          end
          force:set(dv_x * force_factor, dv_y * force_factor, dv_z * force_factor)
          obj:applyForceVector(cid, force)
        end
      end
    end
  end
end

-- Layer 1 mover: observe broadly, but actuate through a small symmetric shell
-- set when possible. If symmetry is unavailable, fall back to the strict
-- refnode trio conservatively.
local function apply_rigid_pull(cluster_pos, cluster_rot, cluster_linvel, cluster_angvel_world,
                                exclude_cids,
                                pull_gain, dp_deadband, dv_deadband, max_dv)
  if not M.layer1_enabled or #layer1_actuator_states == 0 then return end
  local pos = obj:getPosition()
  local current_origin_linvel = vec3(obj:getVelocity())
  local base_x, base_y, base_z = pos.x, pos.y, pos.z
  local current_rot = quat(obj:getRotation())
  local current_local_omega = get_body_gyro_local_omega()
  local centroid_body = get_layer1_centroid_body()
  local current_centroid_offset = current_rot * centroid_body
  local current_angvel_world = current_local_omega:rotated(current_rot)
  local current_centroid_linvel = current_origin_linvel + current_angvel_world:cross(current_centroid_offset)
  local ccx = base_x + current_centroid_offset.x
  local ccy = base_y + current_centroid_offset.y
  local ccz = base_z + current_centroid_offset.z
  local cpx, cpy, cpz = cluster_pos.x, cluster_pos.y, cluster_pos.z
  local lvx, lvy, lvz = cluster_linvel.x, cluster_linvel.y, cluster_linvel.z
  local ax, ay, az = cluster_angvel_world.x, cluster_angvel_world.y, cluster_angvel_world.z
  local dp_deadband_sq = dp_deadband * dp_deadband
  local dv_deadband_sq = dv_deadband * dv_deadband
  local max_dv_sq = max_dv * max_dv
  local exclude = exclude_cids or {}
  local factor = layer1_actuator_force_factor > 0 and layer1_actuator_force_factor or 1

  if M.layer1_geometry_mode == "mirrored_pairs" or M.layer1_geometry_mode == "mirrored_pairs_long_vehicle" then
    local current_euler = current_rot:toEulerYXZ()
    local target_euler = cluster_rot:toEulerYXZ()
    local target_local_omega = cluster_angvel_world:rotated(cluster_rot:inversed())
    local yaw_error = wrap_angle_pi(target_euler.x - current_euler.x)
    local abs_yaw_error = math.abs(yaw_error)
    local abs_target_yaw_rate = math.abs(target_local_omega.z)
    local yaw_settle_boost = 1.0
    if abs_yaw_error > math.rad(1.5) and abs_target_yaw_rate < 0.35 then
      local error_scale = math.min(1.0, (abs_yaw_error - math.rad(1.5)) / math.rad(10.0))
      local calm_scale = math.max(0.0, 1.0 - (abs_target_yaw_rate / 0.35))
      yaw_settle_boost = 1.0 + (1.75 * error_scale * calm_scale)
    end
    local yaw_rot = quatFromEuler(current_euler.y, current_euler.z, target_euler.x)
    local planar_pos = vec3(cpx, cpy, ccz)
    local planar_rot = current_rot
    local planar_linvel = vec3(lvx, lvy, 0)
    local planar_angvel = vec3(0, 0, 0)
    local yaw_only_pos = vec3(ccx, ccy, ccz)
    local yaw_only_linvel = vec3(current_centroid_linvel.x, current_centroid_linvel.y, 0)
    local yaw_only_angvel = vec3(0, 0, az * M.layer1_frame_yaw_rate_gain)
    local frame_factor = average_factor(layer1_frame_refnode_states)
    local planar_pull_gain = pull_gain * M.layer1_frame_planar_gain
    local yaw_pull_gain = pull_gain * M.layer1_frame_yaw_gain * yaw_settle_boost
    local frame_planar_max_dv = M.layer1_frame_planar_max_dv
    local frame_max_dv = M.layer1_frame_yaw_max_dv * math.min(2.0, yaw_settle_boost)
    local support_gain = pull_gain * M.layer1_support_gain
    local support_max_dv = math.min(max_dv * math.max(0.2, M.layer1_support_gain), max_dv)
    local support_rot = quatFromEuler(target_euler.y, target_euler.z, current_euler.x)
    local support_pos = vec3(ccx, ccy, cpz)
    local support_linvel = vec3(current_centroid_linvel.x, current_centroid_linvel.y, lvz)
    local support_local_omega = vec3(target_local_omega.x, target_local_omega.y, 0)
    local support_angvel = support_local_omega:rotated(support_rot)

    apply_rigid_pull_to_states(
      layer1_frame_refnode_states, frame_factor,
      current_centroid_offset, ccx, ccy, ccz, centroid_body,
      planar_pos, planar_rot, planar_linvel, planar_angvel,
      exclude,
      planar_pull_gain, dp_deadband_sq, dv_deadband_sq,
      frame_planar_max_dv, frame_planar_max_dv * frame_planar_max_dv,
      true
    )

    apply_rigid_pull_to_states(
      layer1_frame_refnode_states, frame_factor,
      current_centroid_offset, ccx, ccy, ccz, centroid_body,
      yaw_only_pos, yaw_rot, yaw_only_linvel, yaw_only_angvel,
      exclude,
      yaw_pull_gain, dp_deadband_sq, dv_deadband_sq, frame_max_dv, frame_max_dv * frame_max_dv,
      true
    )

    if support_gain > 0 then
      apply_rigid_pull_to_states(
        layer1_actuator_states, factor,
        current_centroid_offset, ccx, ccy, ccz, centroid_body,
        support_pos, support_rot, support_linvel, support_angvel,
        exclude,
        support_gain, dp_deadband_sq, dv_deadband_sq,
        support_max_dv, support_max_dv * support_max_dv,
        false
      )
    end
    return
  end

  if M.layer1_geometry_mode ~= "mirrored_pairs" and M.layer1_geometry_mode ~= "mirrored_pairs_long_vehicle" then
    pull_gain = pull_gain * 0.5
    max_dv = math.min(max_dv, 4.0)
    max_dv_sq = max_dv * max_dv
  end

  apply_rigid_pull_to_states(
    layer1_actuator_states, factor,
    current_centroid_offset, ccx, ccy, ccz, centroid_body,
    cluster_pos, cluster_rot, cluster_linvel, cluster_angvel_world,
    exclude,
    pull_gain, dp_deadband_sq, dv_deadband_sq, max_dv, max_dv_sq,
    false
  )
end

local function send_vehicle_config()
  local config = v.config
  local r = quat(obj:getRotation())
  local p = obj:getPosition()
  local data = {
    position = {p.x, p.y, p.z},
    rotation = {r.x, r.y, r.z, r.w},
  }
  obj:queueGameEngineLua("vehiclemanager.send_vehicle_config_inner("..obj:getID()..", " .. string.format("%q", jsonEncode(config)) .. ", " .. string.format("%q", jsonEncode(data)) .. ")")
end

M.update_transform_info = update_transform_info
M.update_eligible_nodes = update_eligible_nodes
M.apply_linear_velocity = apply_linear_velocity
M.apply_rigid_pull = apply_rigid_pull
M.set_controller_tuning = set_controller_tuning
M.set_geometry_tuning = set_geometry_tuning
M.draw_layer1_debug = draw_layer1_debug
M.get_layer1_centroid_body = get_layer1_centroid_body
M.get_boundary_cids = get_boundary_cids
M.get_wheel_side_cids = get_wheel_side_cids
M.get_non_core_cids = get_non_core_cids
M.get_layer1_core_cids = get_layer1_core_cids
M.get_layer1_observation_cids = get_layer1_observation_cids
M.get_layer1_actuation_cids = get_layer1_actuation_cids
M.get_layer1_components = get_layer1_components
M.get_layer1_frame_refnode_cids = get_layer1_frame_refnode_cids
M.get_layer1_geometry_mode = get_layer1_geometry_mode
M.get_layer1_stats = get_layer1_stats
M.is_rigid_prop = is_rigid_prop
M.onExtensionLoaded = onExtensionLoaded
M.set_reference = set_reference
M.save_state = save_state
M.send_vehicle_config = send_vehicle_config
return M
