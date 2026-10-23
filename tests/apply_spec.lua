-- Phase 6 applier spec.
--
-- Run with:
--   NVIM_APPNAME=mimic-test nvim --headless -u tests/minimal_init.lua -l tests/apply_spec.lua
--
-- The applier takes an injectable env, so these tests exercise starting,
-- filling, deferring, and reverting without touching real plugins or servers.

local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Lsp = require("mimic.apply.lsp")
local Format = require("mimic.apply.format")
local Lint = require("mimic.apply.lint")
local Apply = require("mimic.apply")
local State = require("mimic.apply.state")
local Existing = require("mimic.detect.existing")

local function context(language, opts)
  opts = opts or {}
  return {
    bufnr = 1,
    filetype = opts.filetype or language,
    language = language,
    root = opts.root or "/proj",
    existing = opts.existing or Existing.empty(),
  }
end

local function entry(owner, action, mechanism, category)
  return {
    category = category or "lsp",
    action = action or "select",
    owner = owner,
    label = owner,
    mechanism = mechanism or "external",
  }
end

local function lsp_env(overrides)
  local env = {
    has_runtime_file = function()
      return false
    end,
    resolve_config = function()
      return { cmd = { "srv", "--stdio" }, filetypes = { "python" } }
    end,
    deepcopy = vim.deepcopy,
    joinpath = vim.fs.joinpath,
    is_file = function()
      return false
    end,
    executable = function()
      return true
    end,
    get_clients = function()
      return {}
    end,
    start = function()
      return 7
    end,
  }
  return vim.tbl_extend("force", env, overrides or {})
end

--------------------------------------------------------------- LSP

State.reset()
local applied = Lsp.apply(entry("basedpyright"), context("python"), lsp_env())
eq(applied.status, "applied", "lsp select applies")
eq(applied.client, 7, "lsp apply records the client id")
eq(#State.clients(), 1, "applied client is tracked")
eq(State.clients()[1].name, "basedpyright", "tracked client name")

State.reset()
eq(Lsp.apply(entry("basedpyright", "keep"), context("python"), lsp_env()), nil, "lsp keep is a no-op")

State.reset()
local deferred = Lsp.apply(
  entry("rust_analyzer"),
  context("rust"),
  lsp_env({
    has_runtime_file = function()
      return true
    end,
  })
)
eq(deferred.status, "deferred", "rust_analyzer defers to rustaceanvim")
eq(deferred.reason, "deferred to rustaceanvim", "rust deferral reason")
eq(#State.deferred(), 1, "lsp deferral is recorded")

State.reset()
local jdtls = Lsp.apply(
  entry("jdtls"),
  context("java"),
  lsp_env({
    has_runtime_file = function()
      return true
    end,
  })
)
eq(jdtls.status, "deferred", "jdtls defers to nvim-jdtls")
eq(jdtls.reason, "deferred to nvim-jdtls", "jdtls deferral reason")

State.reset()
local no_config = Lsp.apply(
  entry("basedpyright"),
  context("python"),
  lsp_env({
    resolve_config = function()
      return nil
    end,
  })
)
eq(no_config.status, "skipped", "missing config is skipped")
eq(#State.skipped(), 1, "lsp skip is recorded")

State.reset()
local not_runnable = Lsp.apply(
  entry("basedpyright"),
  context("python"),
  lsp_env({
    executable = function()
      return false
    end,
  })
)
eq(not_runnable.status, "skipped", "non-runnable command is skipped")

State.reset()
local reused = Lsp.apply(
  entry("basedpyright"),
  context("python"),
  lsp_env({
    get_clients = function()
      return { { id = 7 } }
    end,
  })
)
eq(reused.status, "reused", "an existing client is reused")
eq(#State.clients(), 0, "a reused client is not tracked")

State.reset()
local first_start = Lsp.apply(entry("basedpyright"), context("python"), lsp_env())
eq(first_start.status, "applied", "the first start is applied")
local restart = Lsp.apply(entry("basedpyright"), context("python"), lsp_env())
eq(restart.status, "reused", "a still-starting client is reused")
eq(#State.clients(), 1, "a still-starting client is recorded once")

State.reset()
local captured
local with_venv = Lsp.apply(
  entry("basedpyright"),
  context("python"),
  lsp_env({
    is_file = function(path)
      return path:match("%.venv/bin/python$") ~= nil
    end,
    start = function(config)
      captured = config
      return 8
    end,
  })
)
eq(with_venv.status, "applied", "python server applies with a venv")
eq(captured.settings.python.pythonPath, "/proj/.venv/bin/python", "python interpreter is set")
eq(captured.root_dir, "/proj", "root_dir comes from the context")

State.reset()
local failed = Lsp.apply(
  entry("basedpyright"),
  context("python"),
  lsp_env({
    start = function()
      error("boom")
    end,
  })
)
eq(failed.status, "skipped", "a failing start is skipped")
eq(failed.reason:find("start failed") ~= nil, true, "start failure reason is reported")

State.reset()
local unknown = Lsp.apply(entry("does_not_exist"), context("python"), lsp_env())
eq(unknown.status, "skipped", "unknown tool is skipped")

--------------------------------------------------------------- format

local function format_env(map, overrides)
  local conform = { formatters_by_ft = map or {} }
  local env = {
    loaded = function(name)
      if name == "conform" then
        return conform
      end
      return nil
    end,
    require_module = function()
      error("require_module should not be called when conform is loaded")
    end,
    deepcopy = vim.deepcopy,
  }
  return vim.tbl_extend("force", env, overrides or {}), conform
end

State.reset()
local fenv, conform = format_env({})
local fapplied = Format.apply(entry("ruff", "select", "external", "format"), context("python"), fenv)
eq(fapplied.status, "applied", "external formatter is applied")
eq(conform.formatters_by_ft.python[1], "ruff_fix", "ruff_fix is written")
eq(conform.formatters_by_ft.python[2], "ruff_format", "ruff_format is written")
eq(#State.format_edits(), 1, "format edit is recorded")
eq(State.format_edits()[1].value[1], "ruff_fix", "format edit records the written value")

State.reset()
local fenv2, conform2 = format_env({ python = { "black" } })
local kept = Format.apply(entry("ruff", "select", "external", "format"), context("python"), fenv2)
eq(kept.status, "skipped", "existing formatters are kept")
eq(conform2.formatters_by_ft.python[1], "black", "existing entry is untouched")
eq(#State.format_edits(), 0, "skipped format is not recorded")

State.reset()
local fenv3, conform3 = format_env({})
local lsp_format = Format.apply(entry("clangd", "select", "lsp", "format"), context("c"), fenv3)
eq(lsp_format.status, "applied", "lsp formatter is applied")
eq(conform3.formatters_by_ft.c.lsp_format, "fallback", "lsp fallback is written")

State.reset()
local missing = Format.apply(entry("ruff", "select", "external", "format"), context("python"), {
  loaded = function()
    return nil
  end,
  require_module = function()
    error("not available")
  end,
  deepcopy = vim.deepcopy,
})
eq(missing.status, "deferred", "format defers without conform")

State.reset()
local late = { formatters_by_ft = { python = { "black" } } }
local rechecked = Format.apply(entry("ruff", "select", "external", "format"), context("python"), {
  loaded = function()
    return nil
  end,
  require_module = function()
    return late
  end,
  deepcopy = vim.deepcopy,
})
eq(rechecked.status, "skipped", "the key is rechecked after requiring an integration")

--------------------------------------------------------------- lint

local function lint_env(map, overrides)
  local module = { linters_by_ft = map or {}, linters = { clippy = { cmd = "cargo", args = { "clippy" } } } }
  local env = {
    loaded = function(name)
      if name == "lint" then
        return module
      end
      return nil
    end,
    require_module = function()
      error("require_module should not be called when nvim-lint is loaded")
    end,
    has_augroup = function()
      return false
    end,
    create_lint_trigger = function()
      module.trigger = true
    end,
  }
  return vim.tbl_extend("force", env, overrides or {}), module
end

State.reset()
local lenv, lint = lint_env({})
local lapplied = Lint.apply(entry("ruff", "select", "external", "lint"), context("python"), lenv)
eq(lapplied.status, "applied", "linter is applied")
eq(lint.linters_by_ft.python[1], "ruff", "ruff is written")
eq(#State.lint_edits(), 1, "lint edit is recorded")
eq(State.lint_edits()[1].value[1], "ruff", "lint edit records the written value")
eq(State.lint_names("python")[1], "ruff", "lint names are tracked per filetype")

State.reset()
local lenv2, lint2 = lint_env({ python = { "flake8" } })
local lkept = Lint.apply(entry("ruff", "select", "external", "lint"), context("python"), lenv2)
eq(lkept.status, "skipped", "existing linters are kept")
eq(lint2.linters_by_ft.python[1], "flake8", "existing linter entry is untouched")

State.reset()
local lenv3 = lint_env({})
eq(State.trigger_created(), false, "no trigger before ensure_trigger")
eq(Lint.ensure_trigger(lenv3), true, "a trigger is created when none exists")
eq(State.trigger_created(), true, "trigger creation is recorded")
eq(Lint.ensure_trigger(lenv3), false, "the trigger is created once")

State.reset()
local lenv4 = lint_env({}, {
  has_augroup = function()
    return true
  end,
})
eq(Lint.ensure_trigger(lenv4), false, "an existing nvim-lint trigger is respected")
eq(State.trigger_created(), false, "no trigger is recorded when one exists")

----------------------------------------------------------- definition patch

State.reset()
local penv, plint = lint_env({})
local papplied = Lint.apply(entry("clippy", "select", "external", "lint"), context("rust"), penv)
eq(papplied.status, "applied", "clippy is applied for rust")
eq(plint.linters_by_ft.rust[1], "clippy", "clippy is written for rust")
eq(plint.linters.clippy.ignore_exitcode, true, "the clippy definition tolerates cargo's exit codes")
eq(#State.def_edits(), 1, "the definition write is recorded")
eq(State.def_edits()[1].name, "clippy", "the recorded definition name")
eq(State.def_edits()[1].field, "ignore_exitcode", "the recorded definition field")
eq(State.lint_edits()[1].patched.status, "applied", "the lint ledger carries the patch summary")
eq(papplied.patched.status, "applied", "the applied result reports the patch")
eq(Lint.ensure_trigger(penv), true, "the trigger is created after the definition patch")

Apply.revert(penv)
eq(plint.linters_by_ft.rust, nil, "revert removes the written linter entry")
eq(plint.linters.clippy.ignore_exitcode, nil, "revert restores the definition field")
eq(#State.def_edits(), 0, "revert clears the definition ledger")

State.reset()
local ulint = { linters_by_ft = {}, linters = { clippy = { cmd = "cargo", ignore_exitcode = false } } }
local uenv = {
  loaded = function(name)
    if name == "lint" then
      return ulint
    end
    return nil
  end,
  require_module = function()
    error("require_module should not be called when nvim-lint is loaded")
  end,
}
local uapplied = Lint.apply(entry("clippy", "select", "external", "lint"), context("rust"), uenv)
eq(uapplied.status, "applied", "the linter is still applied")
eq(uapplied.patched.status, "kept", "the patch is kept when the user set the field")
eq(uapplied.patched.reason, "user config", "the kept reason names the user")
eq(ulint.linters.clippy.ignore_exitcode, false, "the user value is not overwritten")
eq(State.lint_edits()[1].patched.status, "kept", "the lint ledger records the kept patch")
eq(#State.def_edits(), 0, "a kept patch is not recorded in the ledger")

State.reset()
local dlint = { linters_by_ft = {}, linters = {} }
local denv = {
  loaded = function(name)
    if name == "lint" then
      return dlint
    end
    return nil
  end,
  require_module = function()
    error("require_module should not be called when nvim-lint is loaded")
  end,
}
local dapplied = Lint.apply(entry("clippy", "select", "external", "lint"), context("rust"), denv)
eq(dapplied.status, "applied", "the linter is applied even without a definition")
eq(dapplied.patched.status, "skipped", "a missing definition is skipped")
eq(dapplied.patched.reason, "definition not found", "the skipped reason names the situation")

State.reset()
local lenv5 = lint_env({})
Lint.apply(entry("ruff", "select", "external", "lint"), context("python"), lenv5)
eq(#State.def_edits(), 0, "linters without ignore_exitcode patch nothing")
eq(Lint.patch_definition({ linter = "ruff", ignore_exitcode = true }, lenv5).status, "skipped", "missing definitions skip")

--------------------------------------------------------------- override

local function override_entry(category, owner, previous)
  return {
    category = category,
    action = "override",
    owner = owner,
    label = owner,
    mechanism = "external",
    previous = previous,
  }
end

State.reset()
local oenv, oconform = format_env({ python = { "black" } })
local oformat = override_entry("format", "ruff", {
  owner = "black",
  label = "Black",
  mechanism = "external",
  source = "user",
})
local oapplied = Format.apply(oformat, context("python"), oenv)
eq(oapplied.status, "applied", "override writes over the existing formatter")
eq(oconform.formatters_by_ft.python[1], "ruff_fix", "override writes the new formatter")
eq(#State.format_edits(), 1, "one override edit is recorded")
eq(State.format_edits()[1].previous[1], "black", "override records the previous value")
eq(State.format_edits()[1].replaced.label, "Black", "override records the replaced label")

local osecond = Format.apply(oformat, context("python"), oenv)
eq(osecond.status, "skipped", "an unchanged override is skipped")
eq(#State.format_edits(), 1, "the ledger keeps one edit per filetype")
eq(State.format_edits()[1].previous[1], "black", "the original previous value survives a skipped override")

Apply.revert(oenv)
eq(oconform.formatters_by_ft.python[1], "black", "revert restores the previous formatter")
eq(#State.format_edits(), 0, "revert clears the format ledger")

State.reset()
local menv, mconform = format_env({ python = { "black" } })
Format.apply(oformat, context("python"), menv)
mconform.formatters_by_ft.python = { "yapf" }
local mchanged = Format.apply(oformat, context("python"), menv)
eq(mchanged.status, "applied", "a changed value is overridden again")
eq(#State.format_edits(), 1, "the ledger stays at one edit per filetype")
eq(State.format_edits()[1].previous[1], "yapf", "the newest previous value is recorded")
Apply.revert(menv)
eq(mconform.formatters_by_ft.python[1], "yapf", "revert restores the newest previous value")

State.reset()
local loenv, lolint = lint_env({ python = { "flake8" } })
local olint = override_entry("lint", "ruff", {
  owner = "flake8",
  label = "Flake8",
  mechanism = "external",
  source = "user",
})
local loapplied = Lint.apply(olint, context("python"), loenv)
eq(loapplied.status, "applied", "lint override applies")
eq(lolint.linters_by_ft.python[1], "ruff", "lint override writes the new linter")
eq(#State.lint_edits(), 1, "one lint override edit is recorded")
eq(State.lint_edits()[1].previous[1], "flake8", "lint override records the previous value")
eq(State.lint_edits()[1].replaced.label, "Flake8", "lint override records the replaced label")
eq(State.lint_names("python")[1], "ruff", "lint override updates the trigger names")

local lsecond = Lint.apply(olint, context("python"), loenv)
eq(lsecond.status, "skipped", "an unchanged lint override is skipped")
eq(#State.lint_edits(), 1, "the lint ledger keeps one edit per filetype")

--------------------------------------------------------------- deferral without nvim-lint

State.reset()
local ldeferred = Lint.apply(entry("ruff", "select", "external", "lint"), context("python"), {
  loaded = function()
    return nil
  end,
  require_module = function()
    error("not available")
  end,
})
eq(ldeferred.status, "deferred", "lint defers without nvim-lint")

--------------------------------------------------------------- reapply after install

State.reset()
local reapply_conform = { formatters_by_ft = {} }
local reapply_plan = {
  analyzed = true,
  categories = {
    lsp = { category = "lsp", action = "none", reason = "no available tool" },
    lint = { category = "lint", action = "none", reason = "no available tool" },
    format = {
      category = "format",
      action = "select",
      owner = "ruff",
      label = "Ruff",
      mechanism = "external",
    },
  },
}
local reapply_env = {
  buf_is_loaded = function()
    return true
  end,
  buftype = function()
    return ""
  end,
  deepcopy = vim.deepcopy,
  deep_equal = vim.deep_equal,
  detect = function()
    local ctx = context("python")
    ctx.enabled = true
    ctx.supported = true
    return ctx
  end,
  is_enabled = function()
    return true
  end,
  list_bufs = function()
    return { 1 }
  end,
  loaded = function(name)
    if name == "conform" then
      return reapply_conform
    end
    return nil
  end,
  plan = function()
    return reapply_plan
  end,
  require_module = function()
    error("require_module should not be called when conform is loaded")
  end,
}

Format.apply(entry("black", "select", "external", "format"), context("python"), reapply_env)
eq(reapply_conform.formatters_by_ft.python[1], "black", "the initial formatter is applied")
eq(State.format_edits()[1].previous, nil, "the initial edit records no previous formatter")

local reapplied = Apply.reapply({}, reapply_env)
eq(#reapplied, 1, "reapply sweeps one loaded buffer")
eq(reapply_conform.formatters_by_ft.python[1], "ruff_fix", "reapply switches to the newly available formatter")
eq(reapply_conform.formatters_by_ft.python[2], "ruff_format", "reapply writes the full formatter list")
eq(State.format_edits()[1].previous, nil, "reapply records the restored value as the previous formatter")

reapply_env.is_enabled = function()
  return false
end
Apply.reapply({}, reapply_env)
eq(reapply_conform.formatters_by_ft.python, nil, "reapply reverts but does not sweep while mimic is disabled")
eq(#State.format_edits(), 0, "disabled reapply clears the ledger")

State.reset()
print("mimic apply spec: ok")
