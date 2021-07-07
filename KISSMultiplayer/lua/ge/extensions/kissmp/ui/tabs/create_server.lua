local M = {}
local imgui = ui_imgui
local http = require("socket.http")

M.map = "/levels/industrial/info.json"
M.map_name = "Industrial"
M.mods = {}
M.server_name = imgui.ArrayChar(128, "Private KissMP server")
M.max_players = imgui.IntPtr(8)
M.port = imgui.IntPtr(3698)
M.is_proton = imgui.BoolPtr(false)
M.proton_path = imgui.ArrayChar(1024, "/home/")

local forced_mods = {}
local pre_forced_mods_state = {}

local function to_non_lowered(path)
  local mods = FS:findFiles("/mods/", "*.zip", 1000)
  for k, v in pairs(mods) do
    if string.lower(v) == path then
      return v
    end
  end
  return path
end

local function host_server()
  local port = M.port[0]
  local mods_converted = {}
  for k, v in pairs(M.mods) do
    table.insert(mods_converted, v)
  end
  if #mods_converted == 0 then
    mods_converted = nil
  end
  local config = {
    name = ffi.string(M.server_name),
    max_players = M.max_players[0],
    map = M.map,
    mods = mods_converted,
    port = port
  }
  local b, _, _  = http.request("http://127.0.0.1:3693/host/"..jsonEncode(config))
  if b == "ok" then
    local player_name = ffi.string(kissui.player_name)
    network.connect("127.0.0.1:"..port, player_name)
  end
end

local function find_map_real_path(map_path)
  local patterns = {"info.json", "*.mis"}
  local found_file = map_path
  
  for _,pattern in pairs(patterns) do
    local files = FS:findFiles(map_path, pattern, 1)
    if #files > 0 then
      found_file = files[1]
      break
    end
  end
  print(found_file)
  return FS:virtual2Native(found_file)
end

local function change_map(map_info, title)
  -- deactivate mods that were activated by last map selection
  for k,v in pairs(forced_mods) do
    if not pre_forced_mods_state[k] then
      M.mods[k] = nil
    end
  end
  forced_mods = {}
  pre_forced_mods_state = {}

  --
  local map_path = map_info.misFilePath
  print(map_path)
  M.map = map_path
  M.map_name = title or map_info.levelName

  local native = find_map_real_path(map_path)
  print(native)
  local _, zip_end = string.find(native, ".zip")
  local _, is_mod = string.find(native, "mods")
  if zip_end and is_mod then
    local mod_file = string.sub(native, 1, zip_end)
    print(mod_file)
    local virtual = to_non_lowered(FS:native2Virtual(mod_file))
    
    pre_forced_mods_state[virtual] = (M.mods[virtual] ~= nil)
    M.mods[virtual] = FS:virtual2Native(virtual)
    forced_mods[virtual] = true
  end
end

local function checkbox(id, checked, allow_click)
  if allow_click == nil then allow_click = allow_click or true end
  
  if not allow_click then imgui.PushStyleVar1(imgui.StyleVar_Alpha, 0.70) end
  local return_value = imgui.Checkbox(id, checked)
  if not allow_click then imgui.PopStyleVar() end
  
  if allow_click then return return_value else return false end
end

local function draw()
  imgui.Text("Server name:")
  imgui.InputText("##host_server_name", M.server_name)
  
  imgui.Text("Max players:")
  if imgui.InputInt("###host_max_players", M.max_players) then
    M.max_players[0] = math.max(1, math.min(255, M.max_players[0]))
  end
  
  imgui.Text("Map:")
  if imgui.BeginCombo("###host_map", M.map_name) then
    for k, v in pairs(core_levels.getList()) do
      local title = v.title
      if title:find("^levels.") then
        title = v.levelName
      end
      if imgui.Selectable1(title.."###host_map_s_"..k) then
        change_map(v, title)
      end
    end
    imgui.EndCombo()
  end

  imgui.Text("Port:")
  if imgui.InputInt("###host_port", M.port) then
    M.port[0] = math.max(0, math.min(65535, M.port[0]))
  end

  local mods = FS:findFiles("/mods/", "*.zip", 1000)
  imgui.Text("Mods:")
  imgui.BeginChild1("###Mods", imgui.ImVec2(0, -30), true)
  for k, v in pairs(mods) do
    if not v:find("KISSMultiplayer") then
      local forced = forced_mods[v] or false
      local checked = imgui.BoolPtr(M.mods[v] ~= nil or forced)
      
      if checkbox(v.."###host_mod"..k, checked, not forced) then
        if checked[0] and not M.mods[v] then
          M.mods[v] = FS:virtual2Native(v)
        elseif not checked[0] then
          M.mods[v] = nil
        end
      end
    end
  end
  imgui.EndChild()

  if imgui.Button("Create Server", imgui.ImVec2(-1, 0)) then
    host_server()
  end
end

M.draw = draw

return M
