local M = {}
local imgui = ui_imgui

local add_favorite_addr = imgui.ArrayChar(128)
local add_favorite_name = imgui.ArrayChar(64, "KissMP Server")

M.favorite_servers = {}

-- Server list update and search
-- spairs from https://stackoverflow.com/a/15706820
local function spairs(t, order)
  local keys = {}
  for k in pairs(t) do keys[#keys+1] = k end
  if order then
    table.sort(keys, function(a,b) return order(t, a, b) end)
  else
    table.sort(keys)
  end
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

local function save_favorites()
  local file = io.open("./settings/kissmp_favorites.json", "w")
  file:write(jsonEncode(M.favorite_servers))
  io.close(file)
end

local function load_favorites(m)
  local kissui = kissui or m
  local file = io.open("./settings/kissmp_favorites.json", "r")
  if file then
    local content = file:read("*a")
    M.favorite_servers = jsonDecode(content) or {}
    io.close(file)
  end
end

local function update_favorites(m)
  local kissui = kissui or m
  local update_count = 0
  for addr, server in pairs(M.favorite_servers) do
    if not server.added_manually then
      local server_from_list = kissui.tabs.server_list.server_list[addr]
      local server_found_in_list = server_from_list ~= nil

      if server_found_in_list then
        server.name = server_from_list.name
        server.description = server_from_list.description
        update_count = update_count + 1
      end
    end
  end

  if update_count > 0 then
    save_favorites(m)
  end
end

-- Favorites tab things
local function add_server_to_favorites(addr, server)
  M.favorite_servers[addr] = {
    name = server.name,
    description = server.description,
    added_manually = false
  }
  save_favorites()
end

local function add_direct_server_to_favorites(addr, name)
  M.favorite_servers[addr] = {
    name = name,
    added_manually = true
  }
  save_favorites()
end

local function remove_server_from_favorites(addr)
  M.favorite_servers[addr] = nil
  save_favorites()
end

local function draw_add_favorite_window()
  if not kissui.gui.isWindowVisible("Add Favorite") then return end

  local display_size = imgui.GetIO().DisplaySize
  imgui.SetNextWindowPos(imgui.ImVec2(display_size.x / 2, display_size.y / 2), imgui.Cond_Always, imgui.ImVec2(0.5, 0.5))

  imgui.SetNextWindowBgAlpha(kissui.window_opacity[0])
  if imgui.Begin("Add Favorite", kissui.gui.getWindowVisibleBoolPtr("Add Favorite"), bor(imgui.WindowFlags_NoScrollbar ,imgui.WindowFlags_NoResize, imgui.WindowFlags_AlwaysAutoResize)) then
    imgui.Text("Name:")
    imgui.SameLine()
    imgui.PushItemWidth(-1)
    imgui.InputText("##favorite_name", add_favorite_name)
    imgui.PopItemWidth()

    imgui.Text("Address:")
    imgui.SameLine()
    imgui.PushItemWidth(-1)
    imgui.InputText("##favorite_addr", add_favorite_addr)
    imgui.PopItemWidth()

    imgui.Dummy(imgui.ImVec2(0, 5))

    local content_width = imgui.GetWindowContentRegionWidth()
    local button_width = content_width * 0.495

    if imgui.Button("Add", imgui.ImVec2(button_width, 0)) then
      local addr = ffi.string(add_favorite_addr)
      local name = ffi.string(add_favorite_name)

      if addr:len() > 0 and name:len() > 0 then
        add_direct_server_to_favorites(addr, name)
      end

      update_filtered_servers()
      kissui.gui.hideWindow("Add Favorite")
    end
    imgui.SameLine()
    if imgui.Button("Cancel", imgui.ImVec2(button_width, 0)) then
      kissui.gui.hideWindow("Add Favorite")
    end
  end
  imgui.End()
end

local function draw_server_description(description)
  local min_height = 64
  local rect_color = imgui.GetColorU322(imgui.ImVec4(0.15, 0.15, 0.15, 1))

  local bg_size = imgui.CalcTextSize(description, nil, false, imgui.GetWindowContentRegionWidth())
  bg_size.y = math.max(min_height, bg_size.y)
  bg_size.x = imgui.GetWindowContentRegionWidth()

  local cursor_pos_before = imgui.GetCursorPos()
  imgui.Dummy(bg_size)
  local r_min = imgui.GetItemRectMin()
  local r_max = imgui.GetItemRectMax()
  local cursor_pos_after = imgui.GetCursorPos()

  imgui.ImDrawList_AddRectFilled(imgui.GetWindowDrawList(), r_min, r_max, rect_color)

  imgui.SetCursorPos(cursor_pos_before)
  imgui.Text(description)
  imgui.SetCursorPos(cursor_pos_after)
  imgui.Spacing(2)
end

local function draw()
  --draw_list_search_and_filters(true)

  local favorites_count = 0

  imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)
  for addr, server in spairs(M.favorite_servers, function(t,a,b) return t[b].name:lower() > t[a].name:lower() end) do
    local server_from_list = kissui.tabs.server_list.server_list[addr]
    local server_found_in_list = server_from_list ~= nil
    favorites_count = favorites_count + 1

    local header = server.name
    if server.added_manually then
      header = header.." [USER]"
    elseif server_found_in_list then
      header = header.." ["..server_from_list.player_count.."/"..server_from_list.max_players.."]"
    else
      header = header.." [OFFLINE]"
    end
    header = header .. "###server_header_"  .. tostring(favorites_count)

    if imgui.CollapsingHeader1(header) then
      imgui.PushTextWrapPos(0)
      imgui.Text("Address: "..addr)

      if server_found_in_list then
        imgui.Text("Map: "..server_from_list.map)
      end

      if server.description and server.description:len() > 0 then
        draw_server_description(server.description)
      end

      imgui.PopTextWrapPos()
      if imgui.Button("Connect###connect_button_" .. tostring(favorites_count)) then
        kissconfig.save_config()
        local player_name = ffi.string(kissui.player_name)
        network.connect(addr, player_name)
      end
      imgui.SameLine()
      if imgui.Button("Remove from Favorites###remove_favorite_button_" .. tostring(favorites_count)) then
        remove_server_from_favorites(addr)
        update_filtered_servers()
      end
    end
  end

  imgui.PushTextWrapPos(0)
  if favorites_count == 0 then
    imgui.Text("Favorites list is empty")
  end
  imgui.PopTextWrapPos()

  imgui.EndChild()

  local content_width = imgui.GetWindowContentRegionWidth()
  local button_width = content_width * 0.495

  if imgui.Button("Refresh list", imgui.ImVec2(button_width, 0)) then
    kissui.tabs.server_list.refresh()
    kissui.tabs.server_list.update_filtered()
  end
  imgui.SameLine()
  if imgui.Button("Add", imgui.ImVec2(button_width, 0)) then
    kissui.gui.showWindow("Add Favorite")
  end
end

M.draw = draw
M.draw_add_favorite_window = draw_add_favorite_window
M.load = load_favorites
M.update = update_favorites
M.add_server_to_favorites = add_server_to_favorites

return M
