local M = {}
local imgui = ui_imgui

-- Local imgui pointer mirrors for each tunable. Built lazily on first
-- draw (after kisstuning has loaded). FloatPtr for float specs,
-- BoolPtr for bool specs.
local mirrors = nil

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
      end
    end

    imgui.PushTextWrapPos(0)
    imgui.TextDisabled(spec.desc)
    imgui.PopTextWrapPos()
    imgui.Dummy(imgui.ImVec2(0, 8))
  end

  imgui.Separator()
  if imgui.Button("Reset to defaults") then
    kisstuning.reset_defaults()
    -- Force mirrors to refresh from the reset state
    build_mirrors()
  end
end

M.draw = draw

return M
