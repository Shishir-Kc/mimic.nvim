---@brief
--- Existing LSP, formatter, and linter configuration for a buffer.
---
--- This module is read only. It prefers runtime state, then declared LazyVim
--- options. It never loads plugins, never starts clients, and never changes
--- configuration. Every record carries source tags so decisions can be
--- explained later.

local Registry = require("mimic.registry")

local M = {}

local defaults = {
  filetype = function(source)
    if type(source) == "number" then
      return vim.bo[source].filetype
    end
    return ""
  end,
  lsp_clients = function(source)
    if type(source) ~= "number" then
      return {}
    end
    return vim.lsp.get_clients({ bufnr = source })
  end,
  lsp_is_enabled = function(name)
    if type(vim.lsp.is_enabled) ~= "function" then
      return false
    end
    return vim.lsp.is_enabled(name) == true
  end,
  lsp_configs = function()
    local config = vim.lsp.config
    if type(config) == "table" and type(config._configs) == "table" then
      return config._configs
    end
    return {}
  end,
  lazyvim_opts = function(plugin)
    if type(LazyVim) == "table" and type(LazyVim.opts) == "function" then
      local ok, opts = pcall(LazyVim.opts, plugin)
      if ok and type(opts) == "table" then
        return opts
      end
    end
    return nil
  end,
  conform = function()
    return package.loaded["conform"]
  end,
  lint = function()
    return package.loaded["lint"]
  end,
  mimic_state = function()
    return package.loaded["mimic.apply.state"]
  end,
  executable = function(exe)
    return vim.fn.executable(exe) == 1
  end,
}

local function resolve(env)
  return vim.tbl_extend("keep", env or {}, defaults)
end

local function mark(sources, name, tag)
  sources[name] = sources[name] or {}
  if not vim.tbl_contains(sources[name], tag) then
    sources[name][#sources[name] + 1] = tag
  end
end

---Collect formatter or linter names for a filetype from a conform or
---nvim-lint style map, including the "*" fallback.
local function names_for_map(map, filetype)
  local names = {}
  if type(map) ~= "table" then
    return names
  end

  local function append(value)
    if type(value) == "table" then
      for _, name in ipairs(value) do
        if type(name) == "string" then
          names[#names + 1] = name
        end
      end
    end
  end

  append(map[filetype])
  append(map["*"])
  return names
end

---Collect linter names, mirroring nvim-lint's fallback order.
local function lint_names(map, filetype)
  local names = {}
  if type(map) ~= "table" then
    return names
  end

  local function append(value)
    if type(value) == "table" then
      for _, name in ipairs(value) do
        if type(name) == "string" then
          names[#names + 1] = name
        end
      end
    end
  end

  local first = map[filetype]
  if type(first) == "table" and #first > 0 then
    append(first)
  else
    append(map["_"])
  end
  append(map["*"])
  return names
end

local function lsp_result()
  return {
    active = {},
    enabled = {},
    disabled = {},
    configured = {},
    roots = {},
    sources = {},
  }
end

---Read the applier ledger without requiring it, so detection stays read only.
---
---@param env table
---@param getter string
---@return table|nil
local function ledger(env, getter)
  local state = env.mimic_state()
  if type(state) ~= "table" or type(state[getter]) ~= "function" then
    return nil
  end
  local ok, entries = pcall(state[getter])
  if not ok or type(entries) ~= "table" then
    return nil
  end
  return entries
end

---Return the value mimic wrote for a filetype, if it still matches.
---
---Detection ignores what mimic itself applied, so the plan explains what mimic
---would do instead of echoing its own effect. A user edit that replaced the
---value no longer matches the ledger and is reported normally.
---
---@param env table
---@param kind "format"|"lint"
---@param map table
---@param filetype string
---@return boolean
local function mimic_owns(env, kind, map, filetype)
  local getter = kind == "format" and "format_edits" or "lint_edits"
  local edits = ledger(env, getter)
  if edits == nil then
    return false
  end

  local current = map[filetype]
  for _, edit in ipairs(edits) do
    if edit.ft == filetype then
      local recorded = edit.value
      if recorded == nil then
        recorded = edit.names
      end
      return recorded ~= nil and vim.deep_equal(current, recorded)
    end
  end
  return false
end

---Copy a formatter or linter map without the filetype key.
local function without_filetype(map, filetype)
  local copy = {}
  for key, value in pairs(map) do
    if key ~= filetype then
      copy[key] = value
    end
  end
  return copy
end

---Client ids that mimic started itself.
---
---@param env table
---@return table<integer, boolean>
local function mimic_clients(env)
  local ids = {}
  for _, entry in ipairs(ledger(env, "clients") or {}) do
    if type(entry.id) == "number" then
      ids[entry.id] = true
    end
  end
  return ids
end

---Detect existing LSP configuration for a language.
---
---@param source integer|string
---@param language string
---@param env table|nil
---@return table
function M.lsp(source, language, env)
  env = resolve(env)
  local result = lsp_result()

  local owned = mimic_clients(env)
  local clients = {}
  for _, client in ipairs(env.lsp_clients(source)) do
    if not owned[client.id] then
      clients[#clients + 1] = client
    end
  end
  local configs = env.lsp_configs()
  local lazy = env.lazyvim_opts("nvim-lspconfig")
  local lazy_servers = nil
  if type(lazy) == "table" and type(lazy.servers) == "table" then
    lazy_servers = lazy.servers
  end

  for _, candidate in ipairs(Registry.candidates(language, "lsp")) do
    local tool = candidate.tool
    local id = tool.id
    local names = { candidate.binding.server }
    for _, alias in ipairs(tool.aliases or {}) do
      names[#names + 1] = alias
    end

    for _, client in ipairs(clients) do
      if vim.tbl_contains(names, client.name) then
        result.active[id] = true
        mark(result.sources, id, "active")
        if client.config and client.config.root_dir then
          result.roots[id] = client.config.root_dir
        end
      end
    end

    for _, name in ipairs(names) do
      if env.lsp_is_enabled(name) then
        result.enabled[id] = true
        mark(result.sources, id, "runtime")
        break
      end
    end

    for _, name in ipairs(names) do
      if configs[name] then
        result.configured[id] = true
        mark(result.sources, id, "declared")
        break
      end
    end

    if lazy_servers then
      for _, name in ipairs(names) do
        local sopts = lazy_servers[name]
        if sopts ~= nil then
          mark(result.sources, id, "lazyvim")
          if sopts == true or (type(sopts) == "table" and sopts.enabled ~= false) then
            result.enabled[id] = true
          else
            result.disabled[id] = true
          end
          break
        end
      end
    end
  end

  return result
end

---Detect existing formatter configuration for a buffer.
---
---@param source integer|string
---@param language string
---@param env table|nil
---@return table
function M.format(source, language, env)
  env = resolve(env)
  local result = {
    configured = {},
    available = {},
    lsp = false,
    sources = {},
  }

  local filetype = env.filetype(source)

  local conform = env.conform()
  if conform and type(conform.formatters_by_ft) == "table" then
    local map = conform.formatters_by_ft
    if mimic_owns(env, "format", map, filetype) then
      map = without_filetype(map, filetype)
    end
    for _, name in ipairs(names_for_map(map, filetype)) do
      result.configured[name] = true
      mark(result.sources, name, "runtime")
    end
    if type(conform.get_formatter_info) == "function" then
      for name in pairs(result.configured) do
        local ok, info = pcall(conform.get_formatter_info, name, source)
        if ok and type(info) == "table" and info.available then
          result.available[name] = true
        end
      end
    end
  end

  local lazy = env.lazyvim_opts("conform.nvim")
  if type(lazy) == "table" and type(lazy.formatters_by_ft) == "table" then
    for _, name in ipairs(names_for_map(lazy.formatters_by_ft, filetype)) do
      result.configured[name] = true
      mark(result.sources, name, "lazyvim")
    end
  end

  for _, client in ipairs(env.lsp_clients(source)) do
    if type(client.supports_method) == "function" then
      local formatting = client:supports_method("textDocument/formatting")
      local range = client:supports_method("textDocument/rangeFormatting")
      if formatting or range then
        result.lsp = true
        break
      end
    end
  end

  return result
end

---Detect existing linter configuration for a buffer.
---
---@param source integer|string
---@param language string
---@param env table|nil
---@return table
function M.lint(source, language, env)
  env = resolve(env)
  local result = {
    configured = {},
    available = {},
    sources = {},
  }

  local filetype = env.filetype(source)
  local lint = env.lint()

  if lint and type(lint.linters_by_ft) == "table" then
    local map = lint.linters_by_ft
    local filtered = mimic_owns(env, "lint", map, filetype)
    if filtered then
      map = without_filetype(map, filetype)
    end

    local names
    if not filtered and type(lint._resolve_linter_by_ft) == "function" then
      local ok, resolved = pcall(lint._resolve_linter_by_ft, filetype)
      names = ok and resolved or lint_names(map, filetype)
    else
      names = lint_names(map, filetype)
    end

    for _, name in ipairs(names) do
      result.configured[name] = true
      mark(result.sources, name, "runtime")
    end

    if type(lint.linters) == "table" then
      for name in pairs(result.configured) do
        local ok, linter = pcall(function()
          return lint.linters[name]
        end)
        if ok and type(linter) == "table" and type(linter.cmd) == "string" and env.executable(linter.cmd) then
          result.available[name] = true
        end
      end
    end
  end

  local lazy = env.lazyvim_opts("nvim-lint")
  if type(lazy) == "table" and type(lazy.linters_by_ft) == "table" then
    for _, name in ipairs(lint_names(lazy.linters_by_ft, filetype)) do
      result.configured[name] = true
      mark(result.sources, name, "lazyvim")
    end
  end

  return result
end

---An empty existing configuration record.
---
---@return table
function M.empty()
  return {
    lsp = lsp_result(),
    format = {
      configured = {},
      available = {},
      lsp = false,
      sources = {},
    },
    lint = {
      configured = {},
      available = {},
      sources = {},
    },
  }
end

---Detect all existing configuration for a buffer.
---
---@param source integer|string
---@param language string
---@param env table|nil
---@return table
function M.analyze(source, language, env)
  return {
    lsp = M.lsp(source, language, env),
    format = M.format(source, language, env),
    lint = M.lint(source, language, env),
  }
end

return M
