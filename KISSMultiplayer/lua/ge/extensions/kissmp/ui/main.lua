local M = {}
local imgui = ui_imgui

if not network then network = require('network') end

local docked = false

local function draw(dt)
  kissui.tabs.favorites.draw_add_favorite_window(gui)
  if kissui.show_download then return end

  if not kissui.gui.isWindowVisible("KissMP") then return end
  if not docked then
    imgui.SetNextWindowBgAlpha(kissui.window_opacity[0])
  end
  imgui.PushStyleVar2(imgui.StyleVar_WindowMinSize, imgui.ImVec2(300, 300))
  imgui.SetNextWindowViewport(imgui.GetMainViewport().ID)
  if imgui.Begin("KissMP "..network.VERSION_STR) then
    docked = imgui.IsWindowDocked()
    imgui.Text("Player name:")
    imgui.InputText("##name", kissui.player_name)
    if network.connection.connected then
      if imgui.Button("Disconnect") then
        network.disconnect()
      end
    end

    imgui.Dummy(imgui.ImVec2(0, 5))

    if imgui.BeginTabBar("server_tabs##") then
      if imgui.BeginTabItem("Server List") then
        kissui.tabs.server_list.draw(dt)
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Direct Connect") then
        kissui.tabs.direct_connect.draw()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Create server") then
        kissui.tabs.create_server.draw()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Favorites") then
        kissui.tabs.favorites.draw()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("History") then
        kissui.tabs.history.draw()
        imgui.EndTabItem()
      end
      if imgui.BeginTabItem("Settings") then
        kissui.tabs.settings.draw()
        imgui.EndTabItem()
      end
      imgui.EndTabBar()
    end
  end
  imgui.End()
end

local function init(m)
  m.tabs.server_list.refresh(m)
  m.tabs.favorites.load(m)
  m.tabs.favorites.update(m)
  m.tabs.server_list.update_filtered(m)
end

M.draw = draw
M.init = init

return M
