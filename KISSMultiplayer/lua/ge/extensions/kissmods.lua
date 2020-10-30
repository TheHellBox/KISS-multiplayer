local M = {}

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
end

local function deactivate_all_mods()
  for k, mod_path in pairs(FS:findFiles("/mods/", "*.zip", 1000)) do
    if string.endswith(mod_path, "KISSMultiplayer.zip") == false then
      FS:unmount(string.lower(mod_path))
    end
  end
end

local function mount_mod(name)
  --local mode = mode or "added"
  --extensions.core_modmanager.workOffChangedMod("/kissmp_mods/"..name, mode)
  FS:mount("/kissmp_mods/"..name)
end

local function mount_mods(list)
  for _, mod in pairs(list) do
    -- Demount mod in case it was mounted before, to refresh it
    deactivate_mod(mod)
    mount_mod(mod)
    --activate_mod(mod)
  end
end

local function check_mods(mod_list)
  local result = {}
  for _, mod in pairs(mod_list) do
    local search_result = FS:findFiles("/kissmp_mods/", mod[1], 1)

    if not search_result[1] then
      table.insert(result, mod[1])
    else
      local file = io.open(search_result[1])
      local len = file:seek("end")
      print("Comparing len:")
      print("file len: "..len)
      print("expected: "..mod[2])
      if len ~= mod[2] then
        table.insert(result, mod[1])
      end
    end
  end
  return result
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

return M
