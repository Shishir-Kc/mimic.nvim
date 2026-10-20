---@brief
--- mimic: adaptive LSP, linter, and formatter selection for Neovim.
---
--- Phase 7 adds an in-memory cache for filesystem evidence. Project evidence
--- and tool availability are cached per language and root, then refreshed by
--- invalidation events, reload, and toggle. Existing configuration and
--- resolved plans are always read fresh.
---
--- Phase 6 adds opt-in override mode on top of the applier: setup() resolves
--- options and stores them, then applies mimic's own choices on FileType,
--- filling conform and nvim-lint gaps, starting only servers mimic owns, and
--- with override enabled replacing a configured linter or formatter with the
--- resolved best external tool. reload and toggle undo what mimic applied.

local Config = require("mimic.config")

local M = {}

M.version = "0.1.0-dev"

M.config = nil
M._opts = nil
M._did_setup = false
M._session_enabled = nil

local function has_runtime_file(paths)
  for _, path in ipairs(paths) do
    if #vim.api.nvim_get_runtime_file(path, false) > 0 then
      return true
    end
  end
  return false
end

local integrations = {
  {
    name = "nvim-lspconfig",
    paths = { "lua/lspconfig.lua", "lua/lspconfig/init.lua" },
    hint = "Required for LSP server definitions.",
  },
  {
    name = "conform.nvim",
    paths = { "lua/conform/init.lua" },
    hint = "Required for formatting.",
  },
  {
    name = "nvim-lint",
    paths = { "lua/lint.lua" },
    hint = "Required for linting.",
  },
  {
    name = "mason.nvim",
    paths = { "lua/mason/init.lua" },
    hint = "Required only for :Mimic install.",
  },
  {
    name = "nvim-jdtls",
    paths = { "lua/jdtls/init.lua", "lua/jdtls.lua" },
    hint = 'Required only for Java support. Add "mfussenegger/nvim-jdtls" to your plugin spec.',
    optional = true,
  },
}

local function notify_warnings(warnings)
  if #warnings == 0 then
    return
  end
  vim.notify_once("mimic: " .. table.concat(warnings, "; "), vim.log.levels.WARN)
end

---Return the integration points and whether each one is available.
---
---Availability is checked through runtime files so that no plugin is loaded
---just to render status or health output.
---
---@return { name: string, available: boolean, hint: string, optional: boolean|nil }[]
function M.integrations()
  local out = {}
  for _, item in ipairs(integrations) do
    out[#out + 1] = {
      name = item.name,
      available = has_runtime_file(item.paths),
      hint = item.hint,
      optional = item.optional,
    }
  end
  return out
end

---Resolve options and store them.
---
---Calling setup more than once without force is a no-op. The optional second
---argument is internal and exists so reload can bypass the guard.
---
---@param opts table|nil
---@param flags { force: boolean|nil }|nil
---@return table
function M.setup(opts, flags)
  flags = flags or {}
  if M._did_setup and not flags.force then
    return M
  end

  local resolved, warnings = Config.resolve(opts)
  M._opts = vim.deepcopy(opts or {})
  M.config = resolved
  M._did_setup = true
  M._session_enabled = nil

  notify_warnings(warnings)

  local detect_ok, Detect = pcall(require, "mimic.detect")
  if detect_ok and type(Detect.setup_autocmds) == "function" then
    Detect.setup_autocmds()
  end

  local ok, Apply = pcall(require, "mimic.apply")
  if ok then
    Apply.setup_autocmds()
    if M.is_enabled() then
      Apply.sweep(M.config)
    end
  end

  return M
end

---Reset state and apply the original options again.
---
---The session toggle is intentionally cleared here so reload restores the
---configured value instead of preserving a temporary override.
---
---@return table
function M.reload()
  local ok, Detect = pcall(require, "mimic.detect")
  if ok and type(Detect.clear) == "function" then
    Detect.clear()
  end

  local resolve_ok, Resolve = pcall(require, "mimic.resolve")
  if resolve_ok and type(Resolve.clear) == "function" then
    Resolve.clear()
  end

  local apply_ok, Apply = pcall(require, "mimic.apply")
  if apply_ok and type(Apply.revert) == "function" then
    Apply.revert()
  end

  return M.setup(M._opts or {}, { force = true })
end

---@return boolean
function M.is_enabled()
  if M._session_enabled ~= nil then
    return M._session_enabled
  end
  return M.config ~= nil and M.config.enabled == true
end

---Toggle mimic for this Neovim session only.
---
---Turning off reverts everything mimic applied. Turning on applies to loaded
---buffers again. Both transitions clear cached evidence so the next plan reads
---the current project and tool state.
---
---@return boolean enabled
function M.toggle()
  M._session_enabled = not M.is_enabled()

  local detect_ok, Detect = pcall(require, "mimic.detect")
  if detect_ok and type(Detect.clear) == "function" then
    Detect.clear()
  end

  local ok, Apply = pcall(require, "mimic.apply")
  if ok then
    if M._session_enabled then
      Apply.sweep(M.config)
    else
      Apply.revert()
    end
  end

  return M._session_enabled
end

local function applied_state()
  local ok, Apply = pcall(require, "mimic.apply")
  if not ok then
    return nil, tostring(Apply)
  end
  local ok_state, snapshot = pcall(Apply.state)
  if not ok_state then
    return nil, tostring(snapshot)
  end
  return snapshot, nil
end

local function cache_summary()
  local ok, result = pcall(function()
    return require("mimic.cache").stats()
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

local function registry_summary()
  local ok, result = pcall(function()
    return require("mimic.registry").stats()
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

local function detect_context()
  local ok, result = pcall(function()
    return require("mimic.detect").context(0, { config = M.config })
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

local function resolve_plan(context)
  if context == nil then
    return nil, nil
  end
  local ok, result = pcall(function()
    return require("mimic.resolve").plan(context, M.config)
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

local function install_proposal(context, plan)
  if context == nil or plan == nil or not plan.analyzed then
    return nil, nil
  end
  local ok, result = pcall(function()
    return require("mimic.install.proposal").build(context, plan, M.config)
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

---Return a plain table used by :Mimic status and :checkhealth mimic.
---
---@return table
function M.status()
  local version = vim.version()
  local neovim = ("%d.%d.%d"):format(version.major, version.minor, version.patch)
  local integrations = M.integrations()
  local java_missing_jdtls = false

  if M.config and M.config.languages.java then
    for _, item in ipairs(integrations) do
      if item.name == "nvim-jdtls" and not item.available then
        java_missing_jdtls = true
        break
      end
    end
  end

  local registry, registry_error = registry_summary()
  local context, context_error = detect_context()
  local plan, plan_error = resolve_plan(context)
  local install, install_error = install_proposal(context, plan)
  local applied, applied_error = applied_state()
  local cache, cache_error = cache_summary()

  return {
    version = M.version,
    neovim = neovim,
    did_setup = M._did_setup,
    enabled = M.is_enabled(),
    override = M.config ~= nil and M.config.override or nil,
    install = M.config ~= nil and M.config.install or nil,
    integrations = integrations,
    registry = registry,
    registry_error = registry_error,
    context = context,
    context_error = context_error,
    plan = plan,
    plan_error = plan_error,
    install_proposal = install,
    install_proposal_error = install_error,
    applied = applied,
    applied_error = applied_error,
    cache = cache,
    cache_error = cache_error,
    java_missing_jdtls = java_missing_jdtls,
  }
end

return M
