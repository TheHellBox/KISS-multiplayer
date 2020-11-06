local M = {}
M.mods = {}

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

local function deactivate_all_mods()
  for k, mod_path in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    if string.endswith(mod_path, "KISSMultiplayer.zip") == false then
      FS:unmount(string.lower(mod_path))
    end
  end
  for k, mod_path in pairs(FS:findFiles("/kissmp_mods/", "*.zip", 1000)) do
    FS:unmount(mod_path)
  end
  core_vehicles.clearCache()
end

local function mount_mod(name)
  --local mode = mode or "added"
  --extensions.core_modmanager.workOffChangedMod("/kissmp_mods/"..name, mode)
  FS:mount("/kissmp_mods/"..name)
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
  local search_result = FS:findFiles("/kissmp_mods/", mod.name, 1)
  if not search_result[1] then
    mod.status = "missing"
  else
    local file = io.open(search_result[1])
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

local function open_file(name)
  if not string.endswith(name, ".zip") then return end
  if not FS:directoryExists("/kissmp_mods/") then
    FS:directoryCreate("/kissmp_mods/")
  end
  local path = "/kissmp_mods/"..name
  print(path)
  if FS:fileExists(path) then
    -- Clear the file(FS:removeFile doesn't really work for some reason)
    local file = io.open(path, "w")
    file:close()
  end
  local file = io.open(path, "a")
  return file
end

M.open_file = open_file
M.check_mods = check_mods
M.mount_mod = mount_mod
M.mount_mods = mount_mods
M.deactivate_all_mods = deactivate_all_mods
M.set_mods_list = set_mods_list
M.update_status_all = update_status_all
M.update_status = update_status

return M
