#!/usr/bin/env lua
-- Test runner for ForkedKISS Lua tests.
-- Runs all test files in tests/lua/**/test_*.lua.
--
-- Usage:
--   lua tests/lua/run_tests.lua              -- run all tests
--   lua tests/lua/run_tests.lua cluster      -- run tests under tests/lua/cluster/
--   lua tests/lua/run_tests.lua -v           -- verbose output
--
-- No framework dependency. Each test file returns a table whose
-- entries are assert-based test functions. Failures print a stack
-- trace and continue to the next test. Exit code is 0 on all-pass,
-- 1 on any failure.

-- Resolve the tests directory so we can run from anywhere
local function script_dir()
  local info = debug.getinfo(1, "S")
  local src = info.source:sub(2)  -- strip leading @
  return src:match("(.*/)") or "./"
end

local TESTS_DIR = script_dir()
local REPO_ROOT = TESTS_DIR:gsub("tests/lua/$", "")

-- Make tests/lua/ the package path root so test files can require stubs
package.path = TESTS_DIR .. "?.lua;" .. TESTS_DIR .. "?/init.lua;" .. package.path
-- Also add the mod's Lua directory so tests can require modules under test
package.path = REPO_ROOT .. "KISSMultiplayer/lua/vehicle/extensions/kiss_mp/?.lua;" .. package.path

-- Install BeamNG stubs globally before loading any modules under test
local stubs = require("stubs.beamng_types")
stubs.install_globals()

-- ============================================================
-- Test runner
-- ============================================================
local verbose = false
local filter = nil
for i = 1, #arg do
  if arg[i] == "-v" or arg[i] == "--verbose" then
    verbose = true
  else
    filter = arg[i]
  end
end

local total_tests = 0
local failed_tests = 0
local failed_names = {}

local function run_test_file(path, file_label)
  local ok, mod_or_err = pcall(dofile, path)
  if not ok then
    print(string.format("  [LOAD ERROR] %s: %s", file_label, mod_or_err))
    failed_tests = failed_tests + 1
    table.insert(failed_names, file_label .. " (load error)")
    return
  end
  if type(mod_or_err) ~= "table" then
    print(string.format("  [SKIP] %s: test file did not return a table", file_label))
    return
  end
  for name, fn in pairs(mod_or_err) do
    if type(fn) == "function" then
      total_tests = total_tests + 1
      local test_ok, err = xpcall(fn, debug.traceback)
      if test_ok then
        if verbose then
          print(string.format("  [ OK ] %s :: %s", file_label, name))
        end
      else
        failed_tests = failed_tests + 1
        table.insert(failed_names, file_label .. " :: " .. name)
        print(string.format("  [FAIL] %s :: %s", file_label, name))
        print("         " .. tostring(err):gsub("\n", "\n         "))
      end
    end
  end
end

-- Walk tests/lua/**/test_*.lua
local function collect_test_files(root, subdir)
  local files = {}
  local dir = subdir and (root .. subdir .. "/") or root
  -- Use ls via io.popen since we can't depend on lfs
  local p = io.popen("find '" .. dir .. "' -type f -name 'test_*.lua' 2>/dev/null")
  if not p then return files end
  for line in p:lines() do
    table.insert(files, line)
  end
  p:close()
  table.sort(files)
  return files
end

local test_files = collect_test_files(TESTS_DIR, filter)

if #test_files == 0 then
  print("No test files found" .. (filter and (" under " .. filter) or ""))
  os.exit(1)
end

print(string.format("Running %d test file(s)...", #test_files))
for _, path in ipairs(test_files) do
  local label = path:gsub(TESTS_DIR, "")
  if verbose then print(label) end
  run_test_file(path, label)
end

print("")
print(string.format("Total: %d  Failed: %d", total_tests, failed_tests))
if failed_tests > 0 then
  print("Failed tests:")
  for _, name in ipairs(failed_names) do
    print("  - " .. name)
  end
  os.exit(1)
end
print("All tests passed.")
os.exit(0)
