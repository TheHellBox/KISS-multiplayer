-- Various UI inputs that are globaly avaiable.
local M = {}
local imgui = ui_imgui

-- TODO: Make saving the player name a bit more better.
M.player_name = imgui.ArrayChar(32, "Unknown")

return M