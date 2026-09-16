local PATH_HISTORY = "/settings/kissmp_directcon_history.json"

local M = {}
local imgui = ui_imgui

local history_index = nil

M.direct_history = {}

local function trim(s)
  return s:gsub("^%s*(.-)%s*$", "%1")
end

local function save_history()
  jsonWriteFile(PATH_HISTORY, M.direct_history, true)
end

local function load_history()
  local json_history = jsonReadFile(PATH_HISTORY)
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

local function connect_to_server(addr)
  local player_name = ffi.string(kissmp_ui.player_name)
  kissmp_config.set_setting("ui.name", player_name)
  kissmp_config.set_setting("ui.addr", addr)
  kissmp_network.connect(addr, player_name, false)
end

local function draw()
  imgui.Text("Server address:")
  imgui.InputText("##addr", kissmp_ui.addr)
  imgui.SameLine()
  if imgui.Button("Connect") then
    local addr = trim(ffi.string(kissmp_ui.addr))
    kissmp_ui.addr = imgui.ArrayChar(128, addr)
    if addr:len() > 0 then
      update_history_for_addr(addr)
    end
    connect_to_server(addr)
  end

  imgui.Spacing()

  imgui.Text("Recent connections:")
  imgui.BeginChild1("##history_list", imgui.ImVec2(0, -30), true)

  if #M.direct_history == 0 then
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "No recent connections")
  else
    for i = 1, #M.direct_history do
      local entry = M.direct_history[i]
      local close_button_width = 20
      if imgui.Button("X##" .. i, imgui.ImVec2(close_button_width, 0)) then
        table.remove(M.direct_history, i)
        history_index = nil
        save_history()
        break
      end

      imgui.SameLine()

      local label = entry.addr .. "###direct_connect_history_" .. i
      local content_width = imgui.GetWindowContentRegionWidth()

      imgui.PushStyleVar2(imgui.StyleVar_ButtonTextAlign, imgui.ImVec2(0.0, 0.5))
      local clicked = imgui.Button(label, imgui.ImVec2(content_width / 2 - close_button_width, 0))
      imgui.PopStyleVar() 
      
      if imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then
        connect_to_server(entry.addr)
      elseif clicked then
        kissmp_ui.addr = imgui.ArrayChar(128, entry.addr)
        history_index = i
      end

    end
  end
  imgui.EndChild()
end

M.draw = draw

load_history()
return M
