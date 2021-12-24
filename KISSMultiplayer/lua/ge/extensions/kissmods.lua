local M = {}
M.mods = {}

local function is_special_mod(mod_path)
  local special_mods = {"kissmultiplayer.zip", "translations.zip"}
  local mod_path_lower = string.lower(mod_path)
  for _, special_mod in pairs(special_mods) do
    if string.endswith(mod_path_lower, special_mod) then
      return true
    end
  end
  return false
end

local function get_mod_name(name)
  local name = string.lower(name)
  name = name:gsub('.zip$', '')
  return "kissmp_mods"..name
end

local function deactivate_mod(name)
  local filename = "/kissmp_mods/"..name
  if FS:isMounted(filename) then
    FS:unmount(filename)
  end
  core_vehicles.clearCache()
end

local function is_app_mod(path)
  local pattern = "([^/]+)%.zip$"
  if string.sub(path, -4) ~= ".zip" then
      pattern = "([^/]+)$"
  end
  
  path = string.match(path, pattern)
  local mod = core_modmanager.getModDB(path)
  if not mod then return false end

  return mod.modType == "app"
end

local function deactivate_all_mods()
  for k, mod_path in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    if not is_special_mod(mod_path) or not is_app_mod(mod_path) then
      FS:unmount(string.lower(mod_path))
    end
  end
  for k, mod_path in pairs(FS:findFiles("/kissmp_mods/", "*.zip", 1000)) do
    FS:unmount(mod_path)
  end
  for k, mod_path in pairs(FS:directoryList("/mods/unpacked/", "*", 1)) do
    if not is_app_mod(mod_path) then
      FS:unmount(mod_path.."/")
    end
  end
  core_vehicles.clearCache()
end

local function mount_mod(name)
  --local mode = mode or "added"
  --extensions.core_modmanager.workOffChangedMod("/kissmp_mods/"..name, mode)
  if FS:fileExists("/kissmp_mods/"..name) then
    FS:mount("/kissmp_mods/"..name)
  else
    files = FS:findFiles("/mods/", name, 1000)
    if files[1] then
      FS:mount(files[1])
    else
      kissui.chat.add_message("Failed to mount mod "..name..", file not found", kissui.COLOR_RED)
    end
  end
  core_vehicles.clearCache()
end

local function mount_mods(list)
  for _, mod in pairs(list) do
    -- Demount mod in case it was mounted before, to refresh it
    deactivate_mod(mod)
    mount_mod(mod)
    --activate_mod(mod)
  end
  core_vehicles.clearCache()
end

local function update_status(mod)
  local search_results = FS:findFiles("/kissmp_mods/", mod.name, 1)
  local search_results2 = FS:findFiles("/mods/", mod.name, 99)

  for _, v in pairs(search_results2) do
    table.insert(search_results, v)
  end
  
  if not search_results[1] then
    mod.status = "missing"
  else
    local file = io.open(search_results[1])
    local len = file:seek("end")
    if len ~= mod.size then
      mod.status = "different"
    else
      mod.status = "ok"
    end
    io.close(file)
  end
end

local function update_status_all()
  for name, mod in pairs(M.mods) do
    update_status(mod)
  end
end

local function set_mods_list(mod_list)
  M.mods = {}
  for _, mod in pairs(mod_list) do
    local mod_name = mod[1]
    local mod_table = {
      name = mod_name,
      size = mod[2],
      status = "unknown"
    }
    M.mods[mod_name] = mod_table
  end
end

local function get_mod_directory()
  if not FS:directoryExists("/kissmp_mods/") then
    FS:directoryCreate("/kissmp_mods/")
  end
  return FS:getFileRealPath("/kissmp_mods/")
end

M.check_mods = check_mods
M.is_special_mod = is_special_mod
M.mount_mod = mount_mod
M.mount_mods = mount_mods
M.deactivate_all_mods = deactivate_all_mods
M.set_mods_list = set_mods_list
M.update_status_all = update_status_all
M.update_status = update_status
M.get_mod_directory = get_mod_directory

return M
