local M = {}
local imgui = ui_imgui

local function draw()
  imgui.Text("Server address (domain or IP):")
  imgui.Text("Use host:port, e.g. play.example.com:3698")
  imgui.InputText("##addr", kissui.addr)
  imgui.SameLine()
  if imgui.Button("Connect") then
    local addr = ffi.string(kissui.addr)
    local player_name = ffi.string(kissui.player_name)
    kissconfig.set_setting("ui.name", player_name)
    kissconfig.set_setting("ui.addr", addr)
    network.connect(addr, player_name, false)
  end
end

M.draw = draw

return M
