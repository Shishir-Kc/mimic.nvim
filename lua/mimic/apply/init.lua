---@brief
--- Applier for mimic: turn a resolved plan into real configuration.
---
--- Applies only what the resolver selected. It fills conform and nvim-lint only
--- when the filetype has no owner, starts only LSP servers mimic owns, defers
--- to provider plugins, and records everything it changed so :Mimic reload and
--- :Mimic toggle can undo it. It never installs anything.

local Detect = require("mimic.detect")
local Resolve = require("mimic.resolve")
local Lsp = require("mimic.apply.lsp")
local Format = require("mimic.apply.format")
local Lint = require("mimic.apply.lint")
local State = require("mimic.apply.state")

local M = {}

M._autocmd_group = nil

local function has_runtime_file(paths)
  for _, path in ipairs(paths or {}) do
    if #vim.api.nvim_get_runtime_file(path, false) > 0 then
      return true
    end
  end
  return false
end

local defaults = nil

local function env_defaults()
  if defaults ~= nil then
    return defaults
  end

  defaults = {
    list_bufs = function()
      return vim.api.nvim_list_bufs()
    end,
    buf_is_loaded = function(bufnr)
      return vim.api.nvim_buf_is_loaded(bufnr)
    end,
    buftype = function(bufnr)
      return vim.bo[bufnr].buftype
    end,
    loaded = function(name)
      return package.loaded[name]
    end,
    require_module = function(name)
      return require(name)
    end,
    deepcopy = vim.deepcopy,
    deep_equal = vim.deep_equal,
    joinpath = vim.fs.joinpath,
    is_file = function(path)
      return vim.fn.filereadable(path) == 1
    end,
    executable = function(exe)
      return vim.fn.executable(exe) == 1
    end,
    has_runtime_file = has_runtime_file,
    resolve_config = function(name)
      return vim.lsp.config[name]
    end,
    get_clients = function()
      return vim.lsp.get_clients()
    end,
    get_client_by_id = function(id)
      return vim.lsp.get_client_by_id(id)
    end,
    start = function(config, opts)
      return vim.lsp.start(config, opts)
    end,
    has_augroup = function(name)
      local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = name })
      return ok and #autocmds > 0
    end,
    create_augroup = function(name, opts)
      return vim.api.nvim_create_augroup(name, opts)
    end,
    create_autocmd = function(event, opts)
      return vim.api.nvim_create_autocmd(event, opts)
    end,
    create_lint_trigger = function()
      vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "InsertLeave" }, {
        group = vim.api.nvim_create_augroup("mimic_lint", { clear = true }),
        callback = function(args)
          local names = State.lint_names(vim.bo[args.buf].filetype)
          if #names > 0 and package.loaded["lint"] then
            require("lint").try_lint(names)
          end
        end,
      })
    end,
    clear_lint_trigger = function()
      vim.api.nvim_create_augroup("mimic_lint", { clear = true })
    end,
    detect = function(bufnr, config)
      return Detect.context(bufnr, { config = config })
    end,
    plan = function(context, config)
      return Resolve.plan(context, config)
    end,
    is_enabled = function()
      return require("mimic").is_enabled()
    end,
  }

  return defaults
end

local function resolve(env)
  return vim.tbl_extend("keep", env or {}, env_defaults())
end

---Apply a plan to a buffer.
---
---@param bufnr integer
---@param context table Detection context.
---@param plan table Resolved plan.
---@param env table|nil Injectable Neovim access.
---@return table|nil
function M.apply(bufnr, context, plan, env)
  env = resolve(env)
  if type(plan) ~= "table" or not plan.analyzed then
    return nil
  end

  local result = {
    bufnr = bufnr,
    filetype = context.filetype,
    language = context.language,
    categories = {},
  }

  result.categories.lsp = Lsp.apply(plan.categories.lsp, context, env)
  result.categories.format = Format.apply(plan.categories.format, context, env)
  result.categories.lint = Lint.apply(plan.categories.lint, context, env)

  local lint = result.categories.lint
  if lint and lint.status == "applied" then
    Lint.ensure_trigger(env)
  end

  return result
end

---Detect, resolve, and apply for one buffer.
---
---@param bufnr integer
---@param config table|nil
---@param env table|nil
---@return table|nil
function M.apply_buffer(bufnr, config, env)
  env = resolve(env)
  local context = env.detect(bufnr, config)
  if type(context) ~= "table" or not context.supported or not context.enabled then
    return nil
  end

  local plan = env.plan(context, config)
  if type(plan) ~= "table" or not plan.analyzed then
    return nil
  end

  return M.apply(bufnr, context, plan, env)
end

---Apply to every loaded file-backed buffer.
---
---@param config table|nil
---@param env table|nil
---@return table[]
function M.sweep(config, env)
  env = resolve(env)
  local results = {}
  for _, bufnr in ipairs(env.list_bufs()) do
    if env.buf_is_loaded(bufnr) and env.buftype(bufnr) == "" then
      local result = M.apply_buffer(bufnr, config, env)
      if result ~= nil then
        results[#results + 1] = result
      end
    end
  end
  return results
end

---Revert mimic's changes, then apply the current plan again.
---
---This is used after an install changes tool availability. Sweeping without a
---revert would leave an older formatter or linter entry in place because the
---select path deliberately does not overwrite an existing entry.
---
---@param config table|nil
---@param env table|nil
---@return table[]
function M.reapply(config, env)
  env = resolve(env)
  M.revert(env)
  if not env.is_enabled() then
    return {}
  end
  return M.sweep(config, env)
end

---Create the FileType autocmd that applies mimic per buffer.
---
---@param env table|nil
function M.setup_autocmds(env)
  env = resolve(env)
  if M._autocmd_group ~= nil then
    return
  end
  M._autocmd_group = env.create_augroup("mimic", { clear = true })
  env.create_autocmd("FileType", {
    group = M._autocmd_group,
    callback = function(args)
      local mimic = require("mimic")
      if not mimic._did_setup or not mimic.is_enabled() then
        return
      end
      M.apply_buffer(args.buf, mimic.config)
    end,
  })
end

---Undo everything mimic applied.
---
---Stops only clients mimic created and removes only entries mimic wrote.
---
---@param env table|nil
function M.revert(env)
  env = resolve(env)

  for _, edit in ipairs(State.format_edits()) do
    local conform = env.loaded("conform")
    if conform and type(conform.formatters_by_ft) == "table" then
      conform.formatters_by_ft[edit.ft] = edit.previous
    end
  end

  for _, edit in ipairs(State.lint_edits()) do
    local lint = env.loaded("lint")
    if lint and type(lint.linters_by_ft) == "table" then
      lint.linters_by_ft[edit.ft] = edit.previous
    end
  end

  for _, edit in ipairs(State.def_edits()) do
    local lint = env.loaded("lint")
    if lint and type(lint.linters) == "table" then
      local definition = lint.linters[edit.name]
      if type(definition) == "table" then
        definition[edit.field] = edit.previous
      end
    end
  end

  if State.trigger_created() then
    env.clear_lint_trigger()
  end

  for _, client in ipairs(State.clients()) do
    local live = env.get_client_by_id(client.id)
    if live ~= nil then
      pcall(function()
        live:stop()
      end)
    end
  end

  State.reset()
end

---Clear the applier ledger.
function M.clear()
  State.reset()
end

---Return a copy of the applier ledger.
---
---@return table
function M.state()
  return State.snapshot()
end

return M
