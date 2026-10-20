-- Phase 8 Mason integration check.
--
-- Run with Mason on the runtimepath:
--   nvim --headless -u tests/minimal_init.lua \
--     --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/mason.nvim' \
--     -l tests/install_integration.lua
--
-- This check is read only. It never refreshes the registry and never installs
-- a package. It skips when Mason has no cached registry, for example in a
-- fresh NVIM_APPNAME profile.

local function has_runtime_file(path)
  return #vim.api.nvim_get_runtime_file(path, false) > 0
end

if not has_runtime_file("lua/mason/init.lua") then
  print("mimic install integration: skipped (mason.nvim not on runtimepath)")
  return
end

local Mason = require("mimic.install.mason")
local Registry = require("mimic.registry")

local available, available_err = Mason.available()
if not available then
  error("mason.nvim is on runtimepath but failed to load: " .. tostring(available_err), 0)
end

local setup, setup_err = Mason.ensure_setup()
if not setup then
  error("mason.setup() failed: " .. tostring(setup_err), 0)
end

local setup_again, setup_again_err = Mason.ensure_setup()
if not setup_again then
  error("mason.setup() guard failed: " .. tostring(setup_again_err), 0)
end

local registry_ok, registry = pcall(require, "mason-registry")
if not registry_ok then
  error("mason-registry failed to load: " .. tostring(registry), 0)
end

local cached = registry.get_all_package_names()
if #cached == 0 then
  print("mimic install integration: skipped (Mason has no cached registry)")
  return
end

local checked = {}
for _, tool in pairs(Registry.tools()) do
  for _, binding in pairs(tool.categories) do
    if binding.mason then
      checked[binding.mason] = true
    end
  end
end

local names = {}
for name in pairs(checked) do
  names[#names + 1] = name
end
table.sort(names)

local missing = {}
for _, name in ipairs(names) do
  local found, find_err = Mason.has_package(name)
  if not found then
    missing[#missing + 1] = ("%s (%s)"):format(name, tostring(find_err or "not found"))
  end
end

if #missing > 0 then
  error("Mason package check failed:\n" .. table.concat(missing, "\n"), 0)
end

local installed, installed_err = Mason.is_installed("ruff")
if installed == nil then
  error("Mason.is_installed() failed: " .. tostring(installed_err), 0)
end

if installed then
  local callback_called = false
  local started, start_err = Mason.install("ruff", function()
    callback_called = true
  end)
  if started ~= false or start_err ~= "already installed" or callback_called then
    error("Mason.install() did not refuse an installed package cleanly", 0)
  end
end

print(("mimic install integration: ok (%d Mason packages, registry %d packages)"):format(#names, #cached))
