local M = {}
local imgui = ui_imgui
local http = require("socket.http")
local VERSION_PRTL = "0.4.4"

local filter_servers_notfull = imgui.BoolPtr(false)
local filter_servers_online = imgui.BoolPtr(false)

local prev_search_text = ""
local prev_filter_notfull = false
local prev_filter_online = false

local search_buffer = imgui.ArrayChar(64)
local time_since_filters_change = 0
local filter_queued = false

local filtered_servers = {}
local filtered_favorite_servers = {}
local next_bridge_status_update = 0

M.server_list = {}

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

local function filter_server_list(list, term, filter_notfull, filter_online, m)
  local kissui = kissui or m
  local return_servers = {}

  local term_trimmed = term:gsub("^%s*(.-)%s*$", "%1")
  local term_lower = term_trimmed:lower()
  local textual_search = term_trimmed:len() > 0

  for addr, server in pairs(list) do
    local server_from_list = M.server_list[addr]
    local server_found_in_list = server_from_list ~= nil

    local discard = false
    if textual_search and not discard then
      local name_lower = server.name:lower()
      discard = discard or not string.find(name_lower, term_lower)
    end
    if filter_notfull and server_found_in_list and not discard then
      discard = discard or server_from_list.player_count >= server_from_list.max_players
    end
    if filter_online and not discard then
      discard = discard or not server_found_in_list
    end

    if not discard then
      return_servers[addr] = server
    end
  end

  return return_servers
end

local function update_filtered_servers(m)
  local kissui = kissui or m
  local term = ffi.string(search_buffer)
  local filter_notfull = filter_servers_notfull[0]
  local filter_online = filter_servers_online[0]

  filtered_servers = filter_server_list(M.server_list, term, filter_notfull, filter_online, m)
  --filtered_favorite_servers = filter_server_list(kissui.tabs.favorites.favorite_servers, term, filter_notfull, filter_online, m)
end

local function refresh_server_list(m)
  local kissui = kissui or m
  local b, _, _  = http.request("http://127.0.0.1:3693/check")
  if b and b == "ok" then
    kissui.bridge_launched = true
  end
  local b, _, _  = http.request("http://127.0.0.1:3693/"..kissui.master_addr.."/"..VERSION_PRTL)
  if b then
    M.server_list = jsonDecode(b) or {}
  end
end

local function draw_list_search_and_filters(show_online_filter)
  imgui.Text("Search:")
  imgui.SameLine()
  imgui.PushItemWidth(-1)
  imgui.InputText("##server_search", search_buffer)
  imgui.PopItemWidth()

  imgui.Text("Filters:")
  imgui.SameLine()

  imgui.Checkbox("Not Full", filter_servers_notfull)
  if show_online_filter then
    imgui.SameLine()
    imgui.Checkbox("Online", filter_servers_online)
  end
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

local function draw(dt)
  -- Search update
  local search_text = ffi.string(search_buffer)
  local filter_notfull = filter_servers_notfull[0]
  local filter_online = filter_servers_online[0]

  if search_text ~= prev_search_text or filter_notfull ~= prev_filter_notfull or filter_online ~= prev_filter_online then
    time_since_filters_change = 0
    filter_queued = true
  end

  prev_search_text = search_text
  prev_filter_notfull = filter_notfull
  prev_filter_online = filter_online

  if time_since_filters_change > 0.5 and filter_queued then
    update_filtered_servers()
    filter_queued = false
  end

  time_since_filters_change = time_since_filters_change + dt

  draw_list_search_and_filters(false)

  local server_count = 0

  imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)
  for addr, server in spairs(filtered_servers, function(t,a,b) return t[a].player_count > t[b].player_count end) do
    server_count = server_count + 1

    local header = server.name.." ["..server.player_count.."/"..server.max_players.."]"
    header = header .. "###server_header_"..tostring(server_count)

    if imgui.CollapsingHeader1(header) then
      imgui.PushTextWrapPos(0)
      imgui.Text("Address: "..addr)
      imgui.Text("Map: "..server.map)
      draw_server_description(server.description)
      imgui.PopTextWrapPos()
      if imgui.Button("Connect###connect_button_" .. tostring(server_count)) then
        kissconfig.save_config()
        local player_name = ffi.string(kissui.player_name)
        network.connect(addr, player_name)
      end

      local in_favorites_list = kissui.tabs.favorites.favorite_servers[addr] ~= nil
      if not in_favorites_list then
        imgui.SameLine()
        if imgui.Button("Add to Favorites###add_favorite_button_" .. tostring(server_count)) then
          kissui.tabs.favorites.add_server_to_favorites(addr, server)
          update_filtered_servers()
        end
      end
    end
  end

  imgui.PushTextWrapPos(0)
  if not kissui.bridge_launched then
    imgui.Text("Bridge is not launched. Please, launch the bridge and then hit 'Refresh list' button")
  elseif server_count == 0 then
    imgui.Text("Server list is empty")
  end
  imgui.PopTextWrapPos()

  imgui.EndChild()

  if imgui.Button("Refresh List", imgui.ImVec2(-1, 0)) then
    refresh_server_list()
    update_filtered_servers()
  end
end

M.draw = draw
M.refresh = refresh_server_list
M.update_filtered = update_filtered_servers

return M
