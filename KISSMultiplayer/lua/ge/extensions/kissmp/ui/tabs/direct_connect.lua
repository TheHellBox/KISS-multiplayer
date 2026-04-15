local M = {}
local imgui = ui_imgui

local history_index = nil

local function trim(s)
  return s:gsub("^%s*(.-)%s*$", "%1")
end

local function get_history()
  if type(kissui.direct_connect_history) ~= "table" then
    kissui.direct_connect_history = {}
  end
  return kissui.direct_connect_history
end

local function update_history_for_addr(addr)
  local history = get_history()
  local now = os.time()

  for i = #history, 1, -1 do
    if history[i].addr == addr then
      table.remove(history, i)
    end
  end

  table.insert(history, 1, {
    addr = addr,
    last_accessed = now,
    last_accessed_text = os.date("%Y-%m-%d %H:%M:%S", now),
  })

  while #history > 5 do
    table.remove(history)
  end

  history_index = nil
end

local function draw()
  imgui.Text("Server address:")
  imgui.InputText("##addr", kissui.addr)
  imgui.SameLine()
  if imgui.Button("Connect") then
    local addr = trim(ffi.string(kissui.addr))
    kissui.addr = imgui.ArrayChar(128, addr)
    if addr:len() > 0 then
      update_history_for_addr(addr)
    end
    local player_name = ffi.string(kissui.player_name)
    kissconfig.save_config()
    network.connect(addr, player_name, false)
  end

  imgui.Spacing()

  imgui.Text("Recent connections:")
  imgui.BeginChild1("##history_list", imgui.ImVec2(0, -30), true)
  local history = get_history()
  if #history == 0 then
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No recent connections")
  else
    for i = 1, #history do
      local entry = history[i]
      if imgui.Button("X##" .. i, imgui.ImVec2(20, 0)) then
        table.remove(history, i)
        history_index = nil
        kissconfig.save_config()
        break
      end
      imgui.SameLine()
      local label = entry.addr .. "###direct_connect_history_" .. i
      if imgui.Selectable1(label, history_index == i) then
        kissui.addr = imgui.ArrayChar(128, entry.addr)
        history_index = i
      end
      imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Last Accessed: " .. (entry.last_accessed_text or ""))

    end
  end
  imgui.EndChild()
end

M.draw = draw

return M
