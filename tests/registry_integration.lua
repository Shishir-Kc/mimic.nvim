local function has_runtime_file(path)
  return #vim.api.nvim_get_runtime_file(path, false) > 0
end

local function read_mason_packages()
  local candidates = {
    vim.fn.expand("~/.local/share/nvim/mason/registries/github/mason-org/mason-registry/registry.json"),
    vim.fn.stdpath("data") .. "/mason/registries/github/mason-org/mason-registry/registry.json",
  }

  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
      if ok and type(data) == "table" then
        local packages = {}
        for _, package in ipairs(data) do
          if type(package) == "table" and type(package.name) == "string" then
            packages[package.name] = true
          end
        end
        return packages
      end
    end
  end

  return nil
end

local Registry = require("mimic.registry")

local valid, errors = Registry.validate()
if not valid then
  error("registry validation failed:\n" .. table.concat(errors, "\n"), 0)
end

local have_lspconfig = has_runtime_file("lua/lspconfig.lua") or has_runtime_file("lua/lspconfig/init.lua")
local have_conform = has_runtime_file("lua/conform/init.lua")
local have_lint = has_runtime_file("lua/lint.lua")
local mason_packages = read_mason_packages()

if not (have_lspconfig or have_conform or have_lint or mason_packages) then
  print("mimic registry integration: skipped (plugin dependencies not on runtimepath)")
  return
end

local checked = { lsp = 0, lint = 0, format = 0, mason = 0 }
local missing = {}

local function check_lsp(server)
  if not have_lspconfig then
    return
  end
  checked.lsp = checked.lsp + 1
  if
    not (has_runtime_file("lsp/" .. server .. ".lua") or has_runtime_file("lua/lspconfig/configs/" .. server .. ".lua"))
  then
    missing[#missing + 1] = "missing lspconfig server: " .. server
  end
end

local function check_lint(linter)
  if not have_lint then
    return
  end
  checked.lint = checked.lint + 1
  if not has_runtime_file("lua/lint/linters/" .. linter .. ".lua") then
    missing[#missing + 1] = "missing nvim-lint linter: " .. linter
  end
end

local function check_format(formatter)
  if not have_conform then
    return
  end
  checked.format = checked.format + 1
  if not has_runtime_file("lua/conform/formatters/" .. formatter .. ".lua") then
    missing[#missing + 1] = "missing conform formatter: " .. formatter
  end
end

local function check_mason(package)
  if not mason_packages then
    return
  end
  checked.mason = checked.mason + 1
  if not mason_packages[package] then
    missing[#missing + 1] = "missing Mason package: " .. package
  end
end

for _, tool in pairs(Registry.tools()) do
  for category, binding in pairs(tool.categories) do
    if category == "lsp" then
      check_lsp(binding.server)
    elseif category == "lint" then
      check_lint(binding.linter)
    elseif category == "format" then
      for _, formatter in ipairs(binding.formatters) do
        check_format(formatter)
      end
    end

    if binding.mason then
      check_mason(binding.mason)
    end
  end
end

if #missing > 0 then
  error("registry integration failed:\n" .. table.concat(missing, "\n"), 0)
end

print(
  ("mimic registry integration: ok (lsp %d, lint %d, format %d, mason %d)"):format(
    checked.lsp,
    checked.lint,
    checked.format,
    checked.mason
  )
)
