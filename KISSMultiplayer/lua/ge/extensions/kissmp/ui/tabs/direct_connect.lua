local M = {}
local imgui = ui_imgui

local function draw()
  imgui.Text("Server address:")
  imgui.InputText("##addr", kissui.addr)
  imgui.SameLine()
  if imgui.Button("Connect") then
    local addr = ffi.string(kissui.addr)
    local player_name = ffi.string(kissui.player_name)
    kissconfig.save_config()
    network.connect(addr, player_name)
  end
end

M.draw = draw

return M
