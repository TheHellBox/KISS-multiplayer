local gui = require("kissmp.ui.gui")
local imgui = gui.imgui
local server_ui = require("kissmp.ui.components.servers")
local servers = require("kissmp.servers")

local add_favorite_addr = imgui.ArrayChar(128)
local add_favorite_name = imgui.ArrayChar(64, "KissMP Server")

local function draw_direct_favorite_add()
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
        servers.add_server_to_favorites(addr, name, nil, true)
      end
      
      server_ui.update_filtered_servers()
      gui.meta.hideWindow("Add Favorite")
    end
    imgui.SameLine()
    if imgui.Button("Cancel", imgui.ImVec2(button_width, 0)) then
      -- TODO: This could be done with some kind of event system. But for now it's fine.
      gui.meta.hideWindow("Add Favorite")
    end
end

-- Blank component for example
local M = {}

local function onExtensionLoaded()
end

local function onUpdate(dt)
  draw_direct_favorite_add()
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M