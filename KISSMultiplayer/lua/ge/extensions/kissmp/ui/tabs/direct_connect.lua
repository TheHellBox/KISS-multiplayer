local M = {}
local imgui = ui_imgui

local history_index = nil

M.direct_history = {}

local function trim(s)
  return s:gsub("^%s*(.-)%s*$", "%1")
end

local function save_history()
  jsonWriteFile("/settings/kissmp_directcon_history.json", M.direct_history, true)
end

local function load_history()
  local json_history = jsonReadFile("/settings/kissmp_directcon_history.json")
  if json_history then
    M.direct_history = json_history
  end
end


local function update_history_for_addr(addr)
  for i = #M.direct_history, 1, -1 do
    if M.direct_history[i].addr == addr then
      table.remove(M.direct_history, i)
    end
  end

  table.insert(M.direct_history, 1, {
    addr = addr
  })

  while #M.direct_history > 5 do
    table.remove(M.direct_history)
  end

  history_index = nil
  save_history()
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

  if #M.direct_history == 0 then
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No recent connections")
  else
    for i = 1, #M.direct_history do
      local entry = M.direct_history[i]
      if imgui.Button("X##" .. i, imgui.ImVec2(20, 0)) then
        table.remove(M.direct_history, i)
        history_index = nil
        save_history()
        break
      end
      imgui.SameLine()
      local label = entry.addr .. "###direct_connect_history_" .. i
      if imgui.Selectable1(label, history_index == i) then
        kissui.addr = imgui.ArrayChar(128, entry.addr)
        history_index = i
      end

    end
  end
  imgui.EndChild()
end

M.draw = draw

load_history()
return M
