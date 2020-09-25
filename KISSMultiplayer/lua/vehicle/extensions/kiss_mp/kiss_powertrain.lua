local M = {}
M.vehicle_path = ""
M.powertrain = {
  device_lookup = {},
  devices = {

  },
  available_device_factories = {},
  loaded_device_factories = {},
  wheels = {}
}

local function build_device_tree(device)
  for _, index in pairs(device.requiredExternalInertiaOutputs or {}) do
    local has_matching_child = false
    for _, child in pairs(device.children) do
      local child = M.powertrain.device_lookup[child]
      if child.inputIndex == index then
        has_matching_child = true
      end
    end

    local counter = 0
    if not has_matching_child then
      local shaft = M.powertrain.loaded_device_factories["shaft"].new(make_dummy_shaft("dummyShaft" .. tostring(counter), device.name, index))
      counter = counter + 1
      shaft.parent = device.name
      if not device.children then
        device.children = {}
      end
      table.insert(device.children, shaft)
    end

    for _, child in pairs(device.children) do
      local child = M.powertrain.device_lookup[child]
      build_device_tree(child)
    end
  end
end

local function init()
  print("Vehicle path: ", M.vehicle_path)
  local global_files = FS:find_files("lua/vehicle/powertrain", "*.lua", -1, true, false)
  local vehicle_files = FS:find_files(M.vehicle_path.."lua/powertrain")
  local all_files = arrayConcat(global_files, vehicle_files)
  for _, file_path in ipairs(all_files or {}) do
    local _, file_name = path.split(file_path)
    file_name = file_name:sub(-1, 5)
    local full_path = "powertrain/"..file_name
    M.powertrain.available_device_factories[file_name] = full_path
  end

  for _, wheel in pairs(wheels.wheelRotators) do
    M.powertrain.wheels[wheel.name] = wheel
  end

  local powertrain_copy = deepcopy(v.data.powertrain)
  for _, jbeam_data in pairs(powertrain_copy) do
    tableMergeRecursive(jbeam_data, v.data[jbeam_data.name] or {})
    local factory_name = available_device_factories[jbeam_data.type]
    if factory_name then
      local device_factory = require(factory_name)
      -- NOTE: We might not need to store loaded_device_factories at all
      M.powertrain.loaded_device_factories[jbeam_data.type] = device_factory
      local device = device_factory.new(jbeam_data)
      M.powertrain.device_lookup[device.name] = device
    end
  end

    -- Building parent/child tree
  for name, device in pairs(M.powertrain.device_lookup) do
    if M.powertrain.device_lookup[device.inputName] then
      if not M.powertrain.device_lookup[device.inputName].children then
        M.powertrain.device_lookup[device.inputName].children = {}
      end
      device.parent = device.inputName
      table.insert(M.powertrain.device_lookup[device.inputName].children, name)
    end
  end

  for _, device in pairs(M.powertrain.device_lookup) do
    if not device.parent then
      build_device_tree(device)
    end
  end
end
