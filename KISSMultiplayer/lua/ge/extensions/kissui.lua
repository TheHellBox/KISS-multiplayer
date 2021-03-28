local M = {}
local http = require("socket.http")

local bor = bit.bor

M.dependencies = {"ui_imgui"}
M.chat = {
  {text = "KissMP chat", has_color = false}
}
M.server_list = {}
M.master_addr = "http://51.210.135.45:3692/"
M.bridge_launched = false

M.show_download = false
M.downloads_info = {}

-- Color constants
M.COLOR_YELLOW = {r = 1, g = 1, b = 0}
M.COLOR_RED = {r = 1, g = 0, b = 0}

M.force_disable_nametags = false

local gui_module = require("ge/extensions/editor/api/gui")
local gui = {setupEditorGuiTheme = nop}
local imgui = ui_imgui

local ui_showing = false

M.addr = imgui.ArrayChar(128)
M.player_name = imgui.ArrayChar(32, "Unknown")
M.show_nametags = imgui.BoolPtr(true)
M.window_opacity = imgui.FloatPtr(0.8)

local add_favorite_addr = imgui.ArrayChar(128)
local add_favorite_name = imgui.ArrayChar(64, "KissMP Server")

local filter_servers_notfull = imgui.BoolPtr(false)
local filter_servers_online = imgui.BoolPtr(false)

local prev_search_text = ""
local prev_filter_notfull = false
local prev_filter_online = false

local search_buffer = imgui.ArrayChar(64)
local time_since_filters_change = 0
local filter_queued = false

local set_column_offset = false
local should_draw_unread_count = false
local unread_message_count = 0
local prev_chat_scroll_max = 0
local message_buffer = imgui.ArrayChar(128)

local favorite_servers = {}

local filtered_servers = {}
local filtered_favorite_servers = {}
local next_bridge_status_update = 0

local function save_favorites()
  local file = io.open("./kissmp_favorites.json", "w")
  file:write(jsonEncode(favorite_servers))
  io.close(file)
end

local function load_favorites()
  local file = io.open("./kissmp_favorites.json", "r")
  if file then
    local content = file:read("*a")
    favorite_servers = jsonDecode(content) or {}
    io.close(file)
  end
end

local function update_favorites()
  local update_count = 0
  for addr, server in pairs(favorite_servers) do
    if not server.added_manually then
      local server_from_list = M.server_list[addr]
      local server_found_in_list = server_from_list ~= nil
      
      if server_found_in_list then
        server.name = server_from_list.name
        server.description = server_from_list.description
        update_count = update_count + 1
      end
    end
  end
  
  if update_count > 0 then 
    save_favorites()
  end
end

-- Server list update and search
-- spairs from https://stackoverflow.com/a/15706820
local function spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys 
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

local function filter_server_list(list, term, filter_notfull, filter_online)
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

local function update_filtered_servers()
    local term = ffi.string(search_buffer)
    local filter_notfull = filter_servers_notfull[0]
    local filter_online = filter_servers_online[0]
  
    filtered_servers = filter_server_list(M.server_list, term, filter_notfull, filter_online)
    filtered_favorite_servers = filter_server_list(favorite_servers, term, filter_notfull, filter_online)
end

local function refresh_server_list()
  local b, _, _  = http.request("http://127.0.0.1:3693/check")
  if b and b == "ok" then
    M.bridge_launched = true
  end
  local b, _, _  = http.request("http://127.0.0.1:3693/"..M.master_addr)
  if b then
    M.server_list = jsonDecode(b) or {}
  end
end

-- Common things
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

-- Favorites tab things
local function add_server_to_favorites(addr, server)
  favorite_servers[addr] = {
    name = server.name,
    description = server.description,
    added_manually = false
  }
  save_favorites()
end

local function add_direct_server_to_favorites(addr, name)
  favorite_servers[addr] = {
    name = name,
    added_manually = true
  }
  save_favorites()
end

local function remove_server_from_favorites(addr)
  favorite_servers[addr] = nil
  save_favorites()
end

local function draw_favorites_tab()
  draw_list_search_and_filters(true)
  
  local favorites_count = 0
  
  imgui.BeginChild1("Scrolling", imgui.ImVec2(0, -30), true)
  for addr, server in spairs(filtered_favorite_servers, function(t,a,b) return t[b].name:lower() > t[a].name:lower() end) do
    local server_from_list = M.server_list[addr]
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
        local player_name = ffi.string(M.player_name)
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
    refresh_server_list()
    update_filtered_servers()
  end
  imgui.SameLine()
  if imgui.Button("Add", imgui.ImVec2(button_width, 0)) then
    gui.showWindow("Add Favorite")
  end
end

-- Servers tab 
local function draw_servers_tab()
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
        local player_name = ffi.string(M.player_name)
        network.connect(addr, player_name)
      end
      
      local in_favorites_list = favorite_servers[addr] ~= nil
      if not in_favorites_list then
        imgui.SameLine()
        if imgui.Button("Add to Favorites###add_favorite_button_" .. tostring(server_count)) then
          add_server_to_favorites(addr, server)
          update_filtered_servers()
        end
      end
    end
  end

  imgui.PushTextWrapPos(0)
  if not M.bridge_launched then
    imgui.Text("Bridge is not launched. Please, launch the bridge and then hit 'Refresh list' button")
  elseif server_count == 0 then
    imgui.Text("Server list is empty")
  end
  imgui.PopTextWrapPos()
  
  imgui.EndChild()
  
  if imgui.Button("Refresh list", imgui.ImVec2(-1, 0)) then
    refresh_server_list()
    update_filtered_servers()
  end
end

-- Direct connect tab
local function draw_direct_connect_tab()
  imgui.Text("Server address:")
  imgui.InputText("##addr", M.addr)
  imgui.SameLine()
  if imgui.Button("Connect") then
    local addr = ffi.string(M.addr)
    local player_name = ffi.string(M.player_name)
    kissconfig.save_config()
    network.connect(addr, player_name)
  end
end

-- Settings tab
local function draw_settings_tab() 
  if imgui.Checkbox("Show Name Tags", M.show_nametags) then
    kissconfig.save_config()
  end
  
  imgui.Text("Window Opacity")
  imgui.SameLine()
  if imgui.SliderFloat("###window_opacity", M.window_opacity, 0, 1) then
    kissconfig.save_config()
  end
end

-- The rest
local function show_ui()
  gui.showWindow("KissMP")
  gui.showWindow("Chat")
  gui.showWindow("Downloads")
  ui_showing = true
end

local function hide_ui()
  gui.hideWindow("KissMP")
  gui.hideWindow("Chat")
  gui.hideWindow("Downloads")
  gui.hideWindow("Add Favorite")
  ui_showing = false
end

local function toggle_ui()
  if not ui_showing then
    show_ui()
  else
    hide_ui()
  end
end

local function open_ui()
  load_favorites()
  refresh_server_list()
  update_filtered_servers()
  update_favorites()
  gui_module.initialize(gui)
  gui.registerWindow("KissMP", imgui.ImVec2(256, 256))
  gui.registerWindow("Chat", imgui.ImVec2(256, 256))
  gui.registerWindow("Downloads", imgui.ImVec2(512, 512))
  gui.registerWindow("Add Favorite", imgui.ImVec2(256, 128))
  gui.registerWindow("Incorrect install detected", imgui.ImVec2(256, 128))
  gui.hideWindow("Add Favorite")
  show_ui()
end

local function draw_add_favorite_window()
  if not gui.isWindowVisible("Add Favorite") then return end
  
  local display_size = imgui.GetIO().DisplaySize
  imgui.SetNextWindowPos(imgui.ImVec2(display_size.x / 2, display_size.y / 2), imgui.Cond_Always, imgui.ImVec2(0.5, 0.5))
  
  imgui.SetNextWindowBgAlpha(M.window_opacity[0])
  if imgui.Begin("Add Favorite", gui.getWindowVisibleBoolPtr("Add Favorite"), bor(imgui.WindowFlags_NoScrollbar ,imgui.WindowFlags_NoResize, imgui.WindowFlags_AlwaysAutoResize)) then        
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
      gui.hideWindow("Add Favorite")
    end
    imgui.SameLine()
    if imgui.Button("Cancel", imgui.ImVec2(button_width, 0)) then
      gui.hideWindow("Add Favorite")
    end    
  end
  imgui.End()
end

local function draw_menu()
  if M.show_download then return end

  if not gui.isWindowVisible("KissMP") then return end
  gui.setupWindow("KissMP")
  imgui.SetNextWindowBgAlpha(M.window_opacity[0])
  if imgui.Begin("KissMP") then
    imgui.Text("Player name:")
    imgui.InputText("##name", M.player_name)
    if network.connection.connected then
      if imgui.Button("Disconnect") then
        network.disconnect()
      end
    end
   
    imgui.Dummy(imgui.ImVec2(0, 5))

    if imgui.BeginTabBar("server_tabs##") then
      if imgui.BeginTabItem("Server List") then
        draw_servers_tab()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Direct Connect") then
        draw_direct_connect_tab()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Favorites") then
        draw_favorites_tab()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Settings") then
        draw_settings_tab()
        imgui.EndTabItem()
      end
      imgui.EndTabBar()
    end
  end
  imgui.End()
end

local function send_current_chat_message()
  local message = ffi.string(message_buffer)
  local message_trimmed = message:gsub("^%s*(.-)%s*$", "%1")
  if message_trimmed:len() == 0 then return end
  
  network.send_data(
    {
      Chat = message_trimmed
    },
    true
  )
  message_buffer = imgui.ArrayChar(128)
end

local function draw_player_list()
  imgui.BeginGroup();
  imgui.Text("Player list:")
  imgui.BeginChild1("PlayerList", imgui.ImVec2(0, 0), true)
  if network.connection.connected then
    for _, player in spairs(network.players, function(t,a,b) return t[b].name:lower() > t[a].name:lower() end) do
      imgui.Text(player.name.."("..player.ping.." ms)")
    end
  end
  imgui.EndChild()
  imgui.EndGroup()
end

local function draw_chat()
  if not gui.isWindowVisible("Chat") then return end
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 100))

  local window_title = "Chat"
  if unread_message_count > 0 and should_draw_unread_count then
    window_title = window_title .. " (" .. tostring(unread_message_count) .. ")"
  end
  window_title = window_title .. "###chat"
  
  imgui.SetNextWindowBgAlpha(M.window_opacity[0])
  if imgui.Begin(window_title) then
    local content_width = imgui.GetWindowContentRegionWidth()
    imgui.BeginChild1("ChatWindowUpperContent", imgui.ImVec2(0, -30), true)
    local upper_content_width = imgui.GetWindowContentRegionWidth()
    imgui.Columns(2, "###chat_columns")
    
    if not set_column_offset then
      -- Imgui doesn't have a "first time" method for this, so we track it ourselves..
      imgui.SetColumnOffset(1, upper_content_width - 175)
      set_column_offset = true

    end
    
    -- Draw messages
    imgui.BeginChild1("Scrolling", imgui.ImVec2(0, 0), false)

    for _, message in pairs(M.chat) do
      imgui.PushTextWrapPos(0)
      if message.has_color then
        imgui.TextColored(imgui.ImVec4(message.color.r or 1, message.color.g or 1, message.color.b or 1, message.color.a or 1), "%s", message.text)
      else
        imgui.Text("%s", message.text)
      end
      imgui.PopTextWrapPos()
    end
    
    -- Scroll to bottom and clear unreads
    local scroll_to_bottom = imgui.GetScrollY() >= prev_chat_scroll_max
    if scroll_to_bottom then
      imgui.SetScrollY(imgui.GetScrollMaxY())
      unread_message_count = 0
    end
    prev_chat_scroll_max = imgui.GetScrollMaxY()
    imgui.EndChild()
    
    -- Draw player list
    imgui.NextColumn()
    draw_player_list()
   
    -- End UpperContent
    imgui.EndChild()
   
    -- Draw chat textbox
    local content_width = imgui.GetWindowContentRegionWidth()
    local button_width = 75
    local textbox_width = content_width - (button_width * 1.075)
    
    imgui.Spacing()
    
    imgui.PushItemWidth(textbox_width)
    if imgui.InputText("##chat", message_buffer, 128, imgui.InputTextFlags_EnterReturnsTrue) then
      send_current_chat_message()
      imgui.SetKeyboardFocusHere(-1)
    end
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button("Send", imgui.ImVec2(button_width, -1)) then
      send_current_chat_message()
    end
    imgui.PopItemWidth()
  end
  imgui.End()
  imgui.PopStyleVar(1)
  should_draw_unread_count = true
end

local function bytes_to_mb(bytes)
  return (bytes / 1024) / 1024
end

local function draw_download()
  if not M.show_download then return end
  
  if not gui.isWindowVisible("Downloads") then return end
  imgui.SetNextWindowBgAlpha(M.window_opacity[0])
  if imgui.Begin("Downloading Required Mods") then
    imgui.BeginChild1("DownloadsScrolling", imgui.ImVec2(0, -30), true)
    
    -- Draw a list of all the downloads, and finish by drawing a total/max size
    local total_size = 0
    local downloaded_size = 0
    
    local content_width = imgui.GetWindowContentRegionWidth()
    local split_width = content_width * 0.495
    
    imgui.PushItemWidth(content_width / 2)
    if network.downloads_status then
      for _, download_status in pairs(network.downloads_status) do
        local text_size = imgui.CalcTextSize(download_status.name)
        local extra_size = split_width - text_size.x
        
        imgui.Text(download_status.name)
        if extra_size > 0 then
          imgui.SameLine()
          imgui.Dummy(imgui.ImVec2(extra_size, -1))
        end
        imgui.SameLine()
        imgui.ProgressBar(download_status.progress, imgui.ImVec2(split_width, 0))
        
        local mod = kissmods.mods[download_status.name]
        total_size = total_size + mod.size
        downloaded_size = downloaded_size + (mod.size * download_status.progress)
      end
    end
    imgui.EndChild()
    
    total_size = bytes_to_mb(total_size)
    downloaded_size = bytes_to_mb(downloaded_size)
    local progress = downloaded_size / total_size
    local progress_text = tostring(math.floor(downloaded_size)) .. "MB / " .. tostring(math.floor(total_size)) .. "MB"
    
    content_width = imgui.GetWindowContentRegionWidth()
    split_width = content_width * 0.495
    local text_size = imgui.CalcTextSize(progress_text)
    local extra_size = split_width - text_size.x
        
    imgui.Text(progress_text)
    if extra_size > 0 then
      imgui.SameLine()
      imgui.Dummy(imgui.ImVec2(extra_size, -1))
    end
    imgui.SameLine()
    if imgui.Button("Cancel###cancel_download", imgui.ImVec2(split_width, -1)) then
      network.cancel_download()
      M.show_download = false
      network.disconnect()
    end
  end
  imgui.End()
end

local function draw_names()
  for id, player in pairs(network.players) do
    local vehicle_id = vehiclemanager.id_map[player.current_vehicle] or 0
    local vehicle = be:getObjectByID(vehicle_id)
    if id ~= network.connection.client_id and vehicle then
      local vehicle_position = vec3(vehicle:getPosition())
      local local_position = be:getPlayerVehicle(0):getPosition()
      local distance = vehicle_position:distance(vec3(local_position))
      vehicle_position.z = vehicle_position.z + 1.6
      debugDrawer:drawTextAdvanced(
        Point3F(vehicle_position.x, vehicle_position.y, vehicle_position.z),
        String(player.name.." ("..tostring(math.floor(distance)).."m)"),
        ColorF(1, 1, 1, 1),
        true,
        false,
        ColorI(0, 0, 0, 255)
      )
    end
  end
end

local function draw_incorrect_install()
  if imgui.Begin("Incorrect install detected") then
    imgui.Text("Incorrect KissMP install. Please, check if mod path is correct")
  end
  imgui.End()
end

local function onUpdate(dt)
  if getMissionFilename() ~= '' and not vehiclemanager.is_network_session then
    return
  end
  draw_menu()
  draw_chat()
  draw_download()
  draw_add_favorite_window()
  if M.incorrect_install then
     draw_incorrect_install()
  end
  if (not M.force_disable_nametags) and M.show_nametags[0] then
    draw_names()
  end
  
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
end

local function add_message(message, color)
  unread_message_count = unread_message_count + 1
  should_draw_unread_count = false
  
  local has_color = color ~= nil and type(color) == 'table'
  local message_table = {
    text = message,
    has_color = has_color
  }
  if has_color then
    message_table.color = color 
  end

  table.insert(M.chat, message_table)
end

M.onExtensionLoaded = open_ui
M.onUpdate = onUpdate
M.add_message = add_message
M.draw_download = draw_download
M.show_ui = show_ui
M.hide_ui = hide_ui
M.toggle_ui = toggle_ui

return M
