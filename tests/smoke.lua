-- Phase 7 smoke test.
--
-- Run with:
--   NVIM_APPNAME=mimic-test nvim --headless -u tests/minimal_init.lua -l tests/smoke.lua

local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Config = require("mimic.config")
local Registry = require("mimic.registry")
local mimic = require("mimic")
local Cache = require("mimic.cache")

eq(vim.fn.exists(":Mimic"), 2, ":Mimic command exists")
eq(#vim.lsp.get_clients(), 0, "loading the registry starts no LSP clients")

local registry_ok, registry_errors = Registry.validate()
eq(registry_ok, true, "registry validates: " .. table.concat(registry_errors, "; "))
eq(Registry.stats().languages, 7, "registry has seven languages")
eq(Registry.filetype_language("cpp"), "cpp", "cpp has its own filetype mapping")

local resolved, warnings = Config.resolve({
  mystery = true,
  languages = { cpp = false },
})

eq(resolved.mystery, nil, "unknown top-level option is ignored")
eq(resolved.languages.cpp, false, "cpp is its own language key")
eq(resolved.languages.c, true, "c remains enabled")
eq(#warnings, 1, "unknown options produce one warning")
eq(warnings[1]:find("mystery") ~= nil, true, "warning names the unknown option")

local defaults = Config.resolve()
eq(type(defaults.override), "table", "override defaults to a table")
eq(defaults.override.lint, false, "override defaults to lint off")
eq(defaults.override.format, false, "override defaults to format off")

local override_true = Config.resolve({ override = true })
eq(override_true.override.lint, true, "override true enables lint")
eq(override_true.override.format, true, "override true enables format")
eq(override_true.override.lsp, false, "override true leaves lsp off")

local override_table, override_warnings = Config.resolve({
  override = { format = true, lsp = true, mystery = true },
})
eq(override_table.override.format, true, "override table enables the named category")
eq(override_table.override.lint, false, "override table leaves unnamed categories off")
eq(override_table.override.lsp, false, "override lsp stays off until implemented")
eq(#override_warnings, 2, "override table reports unknown key and unimplemented lsp")
local joined = table.concat(override_warnings, "; ")
eq(joined:find("mystery") ~= nil, true, "override warning names the unknown category")
eq(joined:find("lsp") ~= nil, true, "override warning names the unimplemented category")

local override_bad, override_bad_warnings = Config.resolve({ override = "yes" })
eq(override_bad.override.lint, false, "invalid override keeps the default")
eq(#override_bad_warnings, 1, "invalid override warns once")

mimic.setup()
eq(mimic.config.enabled, true, "zero-option setup uses enabled default")
eq(mimic.config.languages.cpp, true, "cpp defaults to enabled")

local notices = {}
local old_notify_once = vim.notify_once
vim.notify_once = function(message)
  notices[#notices + 1] = message
end
mimic.setup({ alpha = true, beta = true }, { force = true })
vim.notify_once = old_notify_once
eq(#notices, 1, "setup emits one warning for unknown options")
eq(notices[1]:find("alpha") ~= nil, true, "warning lists the first unknown option")
eq(notices[1]:find("beta") ~= nil, true, "warning lists the second unknown option")

mimic.setup({}, { force = true })
eq(mimic.config.enabled, true, "reset to defaults after the warning test")

mimic.setup({ enabled = false }, { force = true })
eq(mimic.config.enabled, false, "force setup applies options")

mimic.setup({ enabled = true })
eq(mimic.config.enabled, false, "second setup without force is a no-op")

mimic.toggle()
eq(mimic.is_enabled(), true, "toggle changes the session value")

mimic.reload()
eq(mimic.is_enabled(), false, "reload clears session state and reapplies options")
eq(mimic.config.enabled, false, "reload bypasses the double-setup guard")

Cache.fetch("smoke", "reload", function()
  return true
end)
mimic.reload()
eq(Cache.stats().entries, 0, "reload clears cached evidence")

local status = mimic.status()
eq(status.did_setup, true, "status reports setup")
eq(type(status.integrations), "table", "status includes integrations")
eq(status.registry_error, nil, "status reports no registry error")
eq(status.registry.languages, 7, "status includes registry languages")
eq(status.registry.tools >= 20, true, "status includes registry tools")
eq(status.context_error, nil, "status reports no detection error")
eq(type(status.context), "table", "status includes buffer context")
eq(type(status.context.existing), "table", "context includes existing configuration")
eq(status.plan_error, nil, "status reports no resolution error")
eq(type(status.plan), "table", "status includes a plan")
eq(status.plan.analyzed, false, "an unnamed scratch buffer has no plan")
eq(status.plan.reason, "no-filetype", "scratch buffer plan reason")
eq(type(status.plan.categories.lsp), "table", "plan includes an lsp category")
eq(status.applied_error, nil, "status reports no applier error")
eq(type(status.applied), "table", "status includes applied state")
eq(#status.applied.clients, 0, "no LSP clients are started by setup")
eq(#status.applied.format_edits, 0, "no formatter edits on a scratch buffer")
eq(#status.applied.lint_edits, 0, "no linter edits on a scratch buffer")
eq(type(status.cache), "table", "status includes cache statistics")
eq(type(status.cache.entries), "number", "status cache statistics include entries")
eq(status.cache_error, nil, "status reports no cache error")

local mimic_filetype = vim.api.nvim_get_autocmds({ group = "mimic", event = "FileType" })
eq(#mimic_filetype >= 1, true, "setup creates the mimic FileType autocmd")

local cache_autocmds = vim.api.nvim_get_autocmds({ group = "mimic_cache" })
eq(#cache_autocmds >= 4, true, "setup creates the cache invalidation autocmds")

mimic.setup({}, { force = true })
eq(mimic.config.enabled, true, "reset to defaults for the clean run")

Cache.fetch("smoke", "toggle", function()
  return true
end)
mimic.toggle()
eq(mimic.is_enabled(), false, "toggle disables the session")
eq(Cache.stats().entries, 0, "toggle clears cached evidence")

mimic.toggle()
eq(mimic.is_enabled(), true, "toggle enables the session again")
eq(Cache.stats().entries, 0, "toggle clears cached evidence again")

require("mimic.command").dispatch("status")
require("mimic.command").dispatch("install")

local Detect = require("mimic.detect")
local context = Detect.context(0)
eq(type(context), "table", "detection returns a context")
eq(context.supported, false, "an unnamed scratch buffer has no supported language")
eq(context.reason, "no-filetype", "an unnamed scratch buffer reports no filetype")

local Resolve = require("mimic.resolve")
local plan = Resolve.plan(context)
eq(type(plan), "table", "resolution returns a plan")
eq(plan.analyzed, false, "an unnamed scratch buffer cannot be resolved")

local Apply = require("mimic.apply")
eq(Apply.apply(0, context, plan, nil), nil, "an unsupported buffer is never applied")
eq(#Apply.state().clients, 0, "applying an unsupported buffer starts no clients")
Apply.clear()

eq(#vim.lsp.get_clients(), 0, "status, install, detection, resolution, and apply start no LSP clients")

print("mimic smoke: ok")
