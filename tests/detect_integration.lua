local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function has_runtime_file(path)
  return #vim.api.nvim_get_runtime_file(path, false) > 0
end

local Detect = require("mimic.detect")

local have_conform = has_runtime_file("lua/conform/init.lua")
local have_lint = has_runtime_file("lua/lint.lua")
local have_lspconfig = has_runtime_file("lua/lspconfig/init.lua") or has_runtime_file("lua/lspconfig.lua")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.writefile({ "[tool.ruff]", "line-length = 100" }, root .. "/pyproject.toml")
vim.fn.writefile({ '{"devDependencies":{"typescript":"^5.4.0"}}' }, root .. "/package.json")

local bufnr = vim.fn.bufadd(root .. "/src/main.py")
vim.fn.bufload(bufnr)
vim.bo[bufnr].filetype = "python"

local clients_before = #vim.lsp.get_clients()

local context = Detect.context(bufnr, { config = { languages = { python = true } } })

eq(context.language, "python", "integration detects python")
eq(context.supported, true, "integration context supported")
eq(context.root, root, "integration project root")
eq(context.root_source, "pyproject.toml", "integration root source")
eq(context.files["pyproject.toml"] ~= nil, true, "integration records pyproject.toml")
eq(context.packages.typescript, true, "integration reads package.json dependencies")
eq(type(context.existing.lsp), "table", "integration existing lsp table")
eq(type(context.existing.format), "table", "integration existing format table")
eq(type(context.existing.lint), "table", "integration existing lint table")
eq(type(context.availability.ruff), "table", "integration ruff availability")
eq(#vim.lsp.get_clients(), clients_before, "integration starts no LSP clients")

-- Detection must not mutate plugin configuration.
if have_conform then
  local conform = require("conform")
  eq(type(conform.formatters_by_ft), "table", "conform still has a formatter map")
end
if have_lint then
  local lint = require("lint")
  eq(type(lint.linters_by_ft), "table", "nvim-lint still has a linter map")
end

pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
vim.fn.delete(root, "rf")

print(
  ("mimic detect integration: ok (conform %s, lint %s, lspconfig %s)"):format(
    tostring(have_conform),
    tostring(have_lint),
    tostring(have_lspconfig)
  )
)
