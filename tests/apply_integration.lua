-- Phase 6 applier integration check.
--
-- Run with conform.nvim and nvim-lint on the runtimepath:
--   NVIM_APPNAME=mimic-test nvim --headless -u tests/minimal_init.lua \
--     --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
--     --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
--     -l tests/apply_integration.lua
--
-- It uses the real conform and nvim-lint tables and verifies that mimic fills
-- and reverts them without starting any LSP client.

local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Apply = require("mimic.apply")
local Detect = require("mimic.detect")
local Resolve = require("mimic.resolve")
local State = require("mimic.apply.state")

local conform = require("conform")
local lint = require("lint")

State.reset()
conform.formatters_by_ft = {}
lint.linters_by_ft = {}

local context = {
  bufnr = 1,
  filetype = "python",
  language = "python",
  root = "/tmp/mimic-apply-integration",
}

local plan = {
  analyzed = true,
  categories = {
    lsp = { category = "lsp", action = "none", reason = "no available tool" },
    format = { category = "format", action = "select", owner = "ruff", mechanism = "external" },
    lint = { category = "lint", action = "select", owner = "ruff", mechanism = "external" },
  },
}

local clients_before = #vim.lsp.get_clients()
local result = Apply.apply(1, context, plan, nil)

eq(result.categories.format.status, "applied", "integration applies the formatter")
eq(conform.formatters_by_ft.python[1], "ruff_fix", "integration writes ruff_fix")
eq(conform.formatters_by_ft.python[2], "ruff_format", "integration writes ruff_format")
eq(result.categories.lint.status, "applied", "integration applies the linter")
eq(lint.linters_by_ft.python[1], "ruff", "integration writes ruff")
eq(#vim.lsp.get_clients(), clients_before, "integration starts no LSP clients")

local snapshot = Apply.state()
eq(#snapshot.clients, 0, "integration ledger has no clients")
eq(#snapshot.format_edits, 1, "integration records the format edit")
eq(#snapshot.lint_edits, 1, "integration records the lint edit")
eq(snapshot.trigger, true, "integration creates the lint trigger")

Apply.revert()
eq(conform.formatters_by_ft.python, nil, "integration reverts the formatter")
eq(lint.linters_by_ft.python, nil, "integration reverts the linter")
eq(#Apply.state().format_edits, 0, "integration ledger is reset")
eq(#vim.api.nvim_get_autocmds({ group = "mimic_lint" }), 0, "integration removes the lint trigger")

-- A scratch buffer is never applied.
local scratch = vim.api.nvim_create_buf(false, true)
local scratch_context = Detect.context(scratch)
local scratch_plan = Resolve.plan(scratch_context)
eq(Apply.apply(scratch, scratch_context, scratch_plan, nil), nil, "unsupported buffer is not applied")
pcall(vim.api.nvim_buf_delete, scratch, { force = true })

Apply.sweep(nil)
eq(#vim.lsp.get_clients(), clients_before, "sweep starts no LSP clients")

print("mimic apply integration: ok")
