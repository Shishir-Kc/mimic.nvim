local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Detect = require("mimic.detect")
local Resolve = require("mimic.resolve")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.writefile({ "[project]", 'name = "demo"' }, root .. "/pyproject.toml")
vim.fn.writefile({ "[tool.ruff]", "line-length = 100" }, root .. "/ruff.toml")
vim.fn.writefile({ "def main():", "    pass" }, root .. "/src/main.py")

local bufnr = vim.fn.bufadd(root .. "/src/main.py")
vim.fn.bufload(bufnr)
vim.bo[bufnr].filetype = "python"

local clients_before = #vim.lsp.get_clients()

local context = Detect.context(bufnr, { config = { languages = { python = true } } })
local plan = Resolve.plan(context, {
  languages = { python = true },
  categories = { lsp = true, lint = true, format = true },
})

eq(plan.analyzed, true, "integration plan is analyzed")
eq(plan.language, "python", "integration plan language")
eq(plan.root, root, "integration plan root")

local kept = { keep = true, select = true, none = true }
for _, category in ipairs({ "lsp", "lint", "format" }) do
  local entry = plan.categories[category]
  eq(type(entry), "table", "integration plan has " .. category)
  eq(kept[entry.action], true, "integration " .. category .. " action is valid")
  eq(type(entry.providers), "table", "integration " .. category .. " scores providers")

  -- Providers are sorted with eligible entries first.
  local seen_ineligible = false
  for _, provider in ipairs(entry.providers) do
    if not provider.eligible then
      seen_ineligible = true
    elseif seen_ineligible then
      error(("integration %s: eligible provider %s sorted after an ineligible one"):format(category, provider.id), 0)
    end
  end
end

-- When ruff is available, the dedicated ruff.toml is reported in the reason.
local format_entry = plan.categories.format
if format_entry.action == "select" and format_entry.owner == "ruff" then
  eq(format_entry.reason:find("ruff.toml") ~= nil, true, "integration format reason names ruff.toml")
end

eq(#vim.lsp.get_clients(), clients_before, "integration resolution starts no LSP clients")

pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
vim.fn.delete(root, "rf")

print(
  ("mimic resolve integration: ok (lsp %s, lint %s, format %s)"):format(
    plan.categories.lsp.action,
    plan.categories.lint.action,
    plan.categories.format.action
  )
)
