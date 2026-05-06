local M = {}
M.mods = {}

local last_mounted_key = nil

local function mod_set_key(list)
  local names = {}
  for _, name in ipairs(list) do table.insert(names, name) end
  table.sort(names)
  return table.concat(names, "|")
end

function M.is_already_loaded(mod_list)
  if not last_mounted_key then return false end
  return last_mounted_key == mod_set_key(mod_list)
end

function M.mark_as_loaded(mod_list)
  last_mounted_key = mod_set_key(mod_list)
end

local function is_special_mod(mod_path)
  local special_mods = {kissmp_main.install_path, "translations.zip"}
  local mod_path_lower = string.lower(mod_path)
  for _, special_mod in pairs(special_mods) do
    if string.endswith(mod_path_lower, special_mod) then
      return true
    end
  end
  return false
end

local function build_app_mod_set()
  local set = {}
  local pattern = "([^/]+)%.zip$"
  for k, path in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    local name = string.match(path, pattern)
    if name then
      local mod = core_modmanager.getModDB(name)
      if mod and mod.modType == "app" then
        set[name] = true
      end
    end
  end
  return set
end

local function is_app_mod_by_set(path, app_mod_set)
  local pattern = "([^/]+)%.zip$"
  if string.sub(path, -4) ~= ".zip" then
    pattern = "([^/]+)$"
  end
  local name = string.match(path, pattern)
  return name and app_mod_set[name] == true
end

local function deactivate_all_mods()
  last_mounted_key = nil
  local app_mods = build_app_mod_set()
  for k, mod_path in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    if not is_special_mod(mod_path) and not is_app_mod_by_set(mod_path, app_mods) then
      FS:unmount(string.lower(mod_path))
    end
  end
  for k, mod_path in pairs(FS:findFiles("/kissmp_mods/", "*.zip", 1000)) do
    FS:unmount(mod_path)
  end

  local unpacked_mods = FS:directoryList("/mods/unpacked/", "*", 1)
  for k, mod_path in pairs(unpacked_mods) do
    local path = mod_path.."/"
    if path ~= kissmp_main.install_path and not is_app_mod_by_set(mod_path, app_mods) then
      FS:unmount(mod_path.."/")
    end
  end
end

local function mount_mod(name)
  local path = "/kissmp_mods/"..name
  FS:mount(path)
  if not FS:isMounted(path) then
    path = "/mods/"..name
    FS:mount(path)
  end
  if extensions.core_modmanager then
    extensions.core_modmanager.workOffChangedMod(path, "added")
  end
  core_vehicles.clearCache()
end

local function mount_mods(list)
  local mounted_paths = {}
  for _, name in ipairs(list) do
    local path = "/kissmp_mods/"..name
    FS:mount(path)
    if not FS:isMounted(path) then
      path = "/mods/"..name
      FS:mount(path)
    end
    table.insert(mounted_paths, path)
  end
  if extensions.core_modmanager then
    for _, path in ipairs(mounted_paths) do
      extensions.core_modmanager.workOffChangedMod(path, "added")
    end
  end
  core_vehicles.clearCache()
  last_mounted_key = mod_set_key(list)
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
    mod.status = "ok"
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

local function open_file(name)
  if not string.endswith(name, ".zip") then return end
  if not FS:directoryExists("/kissmp_mods/") then
    FS:directoryCreate("/kissmp_mods/")
  end
  local path = "/kissmp_mods/"..name
  local file = io.open(path, "wb")
  return file
end

M.open_file = open_file
M.is_special_mod = is_special_mod
M.mount_mod = mount_mod
M.mount_mods = mount_mods
M.deactivate_all_mods = deactivate_all_mods
M.set_mods_list = set_mods_list
M.update_status_all = update_status_all
M.update_status = update_status
M.is_already_loaded = M.is_already_loaded

M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
end

return M
