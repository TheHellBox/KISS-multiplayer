local gui = require("kissmp.ui.gui")
local imgui = gui.imgui
local utils = require("kissmp.utils")
local inputs = require("kissmp.ui.global_inputs")
local servers = require("kissmp.servers")
local config = require("kissmp.config")

local filter_servers_notfull = imgui.BoolPtr(false)
local filter_servers_online = imgui.BoolPtr(false)
local search_term_buffer = imgui.ArrayChar(64)

local imgui = ui_imgui
local filtered_sorted_servers = {
  online = {},
  favorited = {}
}

local refresh_error = false

local function refresh_servers()
  local success, err = servers.refresh_server_list()
  refresh_error = err
  return success, err
end

local function favorite_server_list_sort(t,a,b)
  local server_a = t[a]
  local server_b = t[b]
  return server_b.name:lower() > server_a.name:lower()
end

local function online_server_list_sort(t,a,b)
  local server_a = t[a]
  local server_b = t[b]
  return server_a.player_count > server_b.player_count
end

local function populate_sort_filter_server_list(from, to, sort_func, search_term, not_full, is_online)
  -- Clear destination table without destroying the reference.
  for k in pairs(to) do
    to[k] = nil
  end

  for address, server in utils.spairs(from, sort_func) do
    local online_server = servers.server_list[address]
    local discard = false
    if not discard and search_term:len() > 0 then
      discard = not string.find(server.name:lower(), search_term)
    end
    if not discard and online_server and not_full then
      discard = online_server.player_count >= online_server.max_players
    end
    if not discard and is_online then
      discard = online_server == nil
    end
    if not discard then
      table.insert(to, {address=address, server=server})
    end
  end
end

local function update_filtered_servers()
  local search_term = ffi.string(search_term_buffer)
  search_term = search_term:gsub("^%s*(.-)%s*$", "%1")
  search_term = search_term:lower()
  local not_full = filter_servers_notfull
  local is_online = filter_servers_online

  populate_sort_filter_server_list(
    servers.server_list,
    filtered_sorted_servers.online,
    online_server_list_sort,
    search_term,
    not_full,
    is_online
  )
  populate_sort_filter_server_list(
    servers.favorite_servers,
    filtered_sorted_servers.favorited,
    favorite_server_list_sort,
    search_term,
    not_full,
    is_online
  )
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

-- indicate_favorite shows a star for favorite servers, primarily for online server listings
local function draw_server_row(index, address, server, indicate_favorite)
  local online_server = servers.server_list[address]
  local header = server.name.." ["

  if indicate_favorite and servers.favorite_servers[address] then
    header = header.." ★ "
  end

  if server.added_manually then
    -- If it appears in the server list, try to get information from there too.
    if online_server then
      header = header.."USER "..online_server.player_count.."/"..online_server.max_players
    else
      header = header.."USER"
    end
  elseif online_server then
    header = header..online_server.player_count.."/"..online_server.max_players
  else
    header = header.."OFFLINE"
  end

  header = header .. "]###server_header_"..tostring(index)

  if imgui.CollapsingHeader1(header) then
    imgui.PushTextWrapPos(0)
    imgui.Text("Address: "..address)
    if online_server then
      imgui.Text("Map: "..online_server.map)
      if online_server.description and online_server.description:len() > 0 then
        draw_server_description(server.description)
      end
    end

    imgui.PopTextWrapPos()

    if imgui.Button("Connect###connect_button_" .. tostring(index)) then
      local player_name = ffi.string(inputs.player_name)
      config.config.name = player_name
      config.save_config()
      network.connect(address, player_name)
    end

    imgui.SameLine()

    if servers.favorite_servers[address] == nil then
      if imgui.Button("Add to Favorites###add_favorite_button_" .. tostring(index)) then
        servers.add_server_to_favorites(address, server.name, server.description, false)
        update_filtered_servers()
      end
    else
      if imgui.Button("Remove from Favorites###remove_favorite_button_" .. tostring(index)) then
        servers.remove_server_from_favorites(address)
        update_filtered_servers()
      end
    end
  end
end

local function draw_servers(favorites_only)
  imgui.Text("Search:")
  imgui.SameLine()
  imgui.PushItemWidth(-1)
  imgui.InputText("##server_search", search_term_buffer)
  imgui.PopItemWidth()
  
  imgui.Text("Filters:")
  imgui.SameLine()
  
  imgui.Checkbox("Not Full", filter_servers_notfull)
  local server_list = false
  if favorites_only then
    imgui.SameLine()
    imgui.Checkbox("Online", filter_servers_online)
    server_list = filtered_sorted_servers.favorited
  else
    server_list = filtered_sorted_servers.online
  end

  local server_count = 0

  imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)
  for index, obj in ipairs(server_list) do
    server_count = server_count + 1
    draw_server_row(index, obj.address, obj.server, not favorites_only)
  end

  imgui.PushTextWrapPos(0)
  if refresh_error then
    imgui.Text(refresh_error)
  elseif server_count == 0 then
    imgui.Text("Server list is empty")
  end

  imgui.PopTextWrapPos()
  imgui.EndChild()

  if imgui.Button("Refresh list", imgui.ImVec2(-1, 0)) then
    refresh_servers()
    update_filtered_servers()
  end
end

-- Server List Component
local M = {}

local time_since_filters_change = 0
local filter_queued = false

local prev_search_text = ""
local prev_filter_notfull = false
local prev_filter_online = false

local function onExtensionLoaded()
  refresh_servers()
  update_filtered_servers()
end

-- TODO: This looks...weird having favorites parameter here.
local function onUpdate(dt, favorites)
  draw_servers(favorites)
  -- Search update
  local search_text = ffi.string(search_term_buffer)
  local filter_notfull = filter_servers_notfull[0]
  local filter_online = filter_servers_online[0]
  
  if 
    search_text ~= prev_search_text or
    filter_notfull ~= prev_filter_notfull or
    filter_online ~= prev_filter_online
  then
    time_since_filters_change = 0
    filter_queued = true
  end
  
  prev_search_text = search_text
  prev_filter_notfull = filter_notfull
  prev_filter_online = filter_online
  
  if filter_queued then
    time_since_filters_change = time_since_filters_change + dt
    if time_since_filters_change > 0.5 and filter_queued then
      update_filtered_servers()
      filter_queued = false
    end
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.update_filtered_servers = update_filtered_servers

return M