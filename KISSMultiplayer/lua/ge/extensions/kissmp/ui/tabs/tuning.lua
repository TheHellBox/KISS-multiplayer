local M = {}
local imgui = ui_imgui

-- Local imgui pointer mirrors for each tunable. Built lazily on first
-- draw (after kisstuning has loaded). FloatPtr for float specs,
-- BoolPtr for bool specs.
local mirrors = nil

-- Cluster debug overlay state. Not a tunable because it lives on the
-- vehicle side (cluster_debug_draw.view_mode) and has no numeric
-- plumbing through kiss_transforms.update(). We push changes across
-- to every vehicle via be:queueAllObjectLua.
local CLUSTER_VIEW_MODES = {"off", "clusters", "regions", "both"}
local cluster_view_mode_idx = imgui.IntPtr(2)  -- default "clusters"

local function push_cluster_view_mode(mode)
  local lua
  if mode == "off" then
    lua = "if cluster_debug_draw then cluster_debug_draw.enabled = false end"
  else
    lua = string.format(
      "if cluster_debug_draw then cluster_debug_draw.enabled = true; cluster_debug_draw.view_mode = %q end",
      mode
    )
  end
  if be and be.queueAllObjectLua then
    be:queueAllObjectLua(lua)
  end
end

local function build_mirrors()
  mirrors = {}
  for _, spec in ipairs(kisstuning.specs) do
    local live = kisstuning.get(spec.key)
    if spec.type == "bool" then
      local v = live
      if v == nil then v = spec.default end
      mirrors[spec.key] = imgui.BoolPtr(v and true or false)
    else
      mirrors[spec.key] = imgui.FloatPtr(live or spec.default)
    end
  end
end

local function draw()
  if not kisstuning then
    imgui.Text("Tuning module not loaded.")
    return
  end
  if not mirrors then build_mirrors() end

  imgui.PushTextWrapPos(0)
  imgui.TextDisabled(
    "Coupled rig heading correction. Local only — each player tunes their "
    .. "own rendering of remote trucks. Share values out of band if you "
    .. "want everyone on the same settings."
  )
  imgui.PopTextWrapPos()
  imgui.Separator()
  imgui.Dummy(imgui.ImVec2(0, 5))

  for _, spec in ipairs(kisstuning.specs) do
    local ptr = mirrors[spec.key]
    local live = kisstuning.get(spec.key)

    if spec.type == "bool" then
      -- Sync mirror from live state if it changed externally
      local cur = ptr[0]
      if (cur and true or false) ~= (live and true or false) then
        ptr[0] = live and true or false
      end
      if imgui.Checkbox(spec.label .. "##" .. spec.key, ptr) then
        kisstuning.set(spec.key, ptr[0] and true or false)
      end
    else
      -- Sync mirror from live state if it changed externally
      if live and math.abs(ptr[0] - live) > 1e-6 then
        ptr[0] = live
      end
      imgui.Text(spec.label)
      if imgui.SliderFloat("##" .. spec.key, ptr, spec.min, spec.max) then
        kisstuning.set(spec.key, ptr[0])
        -- Sliders that live on the VEHICLE side (not plumbed through
        -- kiss_transforms.update() args) need an explicit push via
        -- queueAllObjectLua. cluster_convergence_gain is one of these
        -- because it's read from cluster_state.const inside the
        -- per-tick force path, not passed as an update() arg.
        if spec.key == "cluster_convergence_gain" and be and be.queueAllObjectLua then
          be:queueAllObjectLua(string.format(
            "if cluster_state and cluster_state.const then cluster_state.const.CONVERGENCE_GAIN = %f end",
            ptr[0]
          ))
        end
      end
    end

    imgui.PushTextWrapPos(0)
    imgui.TextDisabled(spec.desc)
    imgui.PopTextWrapPos()
    imgui.Dummy(imgui.ImVec2(0, 8))
  end

  imgui.Separator()
  imgui.Text("Cluster debug overlay")
  imgui.PushTextWrapPos(0)
  imgui.TextDisabled(
    "3D wireframe visualization of the cluster sync topology. "
    .. "Clusters = rigid-body partitions used by sync (thick, vivid). "
    .. "Regions = JBeam semantic groups used by future damage-sync LOD "
    .. "(thin, pastel). Purely diagnostic — no gameplay effect."
  )
  imgui.PopTextWrapPos()
  imgui.Text(string.format("Active: %s", CLUSTER_VIEW_MODES[cluster_view_mode_idx[0] + 1]))
  for i, mode in ipairs(CLUSTER_VIEW_MODES) do
    local label = (cluster_view_mode_idx[0] == i - 1) and ("[" .. mode .. "]") or mode
    if imgui.Button(label .. "##cluster_view_mode_" .. mode) then
      cluster_view_mode_idx[0] = i - 1
      push_cluster_view_mode(mode)
    end
    if i < #CLUSTER_VIEW_MODES then imgui.SameLine() end
  end
  imgui.Dummy(imgui.ImVec2(0, 8))

  imgui.Separator()
  if imgui.Button("Reset to defaults") then
    kisstuning.reset_defaults()
    -- Force mirrors to refresh from the reset state
    build_mirrors()
  end
end

M.draw = draw

return M
