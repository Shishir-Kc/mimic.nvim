-- Phase 6 override integration check.
--
-- Run with conform.nvim and nvim-lint on the runtimepath:
--   NVIM_APPNAME=mimic-test nvim --headless -u tests/minimal_init.lua \
--     --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
--     --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
--     -l tests/override_integration.lua
--
-- It uses the real conform and nvim-lint tables, pre-configures Black and
-- Flake8, applies an override plan, and verifies that revert restores them
-- without starting any LSP client.

local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Apply = require("mimic.apply")
local State = require("mimic.apply.state")

local conform = require("conform")
local lint = require("lint")

State.reset()
conform.formatters_by_ft = { python = { "black" } }
lint.linters_by_ft = { python = { "flake8" } }

local black = conform.formatters_by_ft.python
local flake8 = lint.linters_by_ft.python

local context = {
  bufnr = 1,
  filetype = "python",
  language = "python",
  root = "/tmp/mimic-override-integration",
}

local plan = {
  analyzed = true,
  categories = {
    lsp = { category = "lsp", action = "none", reason = "no available tool" },
    format = {
      category = "format",
      action = "override",
      owner = "ruff",
      label = "Ruff",
      mechanism = "external",
      previous = { owner = "black", label = "Black", mechanism = "external", source = "user" },
    },
    lint = {
      category = "lint",
      action = "override",
      owner = "ruff",
      label = "Ruff",
      mechanism = "external",
      previous = { owner = "flake8", label = "Flake8", mechanism = "external", source = "user" },
    },
  },
}

local clients_before = #vim.lsp.get_clients()
local result = Apply.apply(1, context, plan, nil)

eq(result.categories.format.status, "applied", "override applies the formatter")
eq(conform.formatters_by_ft.python[1], "ruff_fix", "override writes ruff_fix")
eq(conform.formatters_by_ft.python[2], "ruff_format", "override writes ruff_format")
eq(result.categories.lint.status, "applied", "override applies the linter")
eq(lint.linters_by_ft.python[1], "ruff", "override writes ruff")
eq(#vim.lsp.get_clients(), clients_before, "override starts no LSP clients")

local snapshot = Apply.state()
eq(#snapshot.format_edits, 1, "override records one format edit")
eq(#snapshot.lint_edits, 1, "override records one lint edit")
eq(vim.deep_equal(snapshot.format_edits[1].previous, black), true, "format edit records the original value")
eq(snapshot.format_edits[1].replaced.label, "Black", "format edit records the replaced label")
eq(snapshot.lint_edits[1].replaced.label, "Flake8", "lint edit records the replaced label")

-- A second apply with the same value is a no-op and keeps the original previous.
local again = Apply.apply(1, context, plan, nil)
eq(again.categories.format.status, "skipped", "an unchanged override is skipped")
eq(#Apply.state().format_edits, 1, "the ledger keeps one format edit")

Apply.revert()
eq(conform.formatters_by_ft.python, black, "revert restores the Black table")
eq(lint.linters_by_ft.python, flake8, "revert restores the Flake8 table")
eq(#Apply.state().format_edits, 0, "revert clears the format ledger")
eq(#vim.lsp.get_clients(), clients_before, "revert starts no LSP clients")

print("mimic override integration: ok")
