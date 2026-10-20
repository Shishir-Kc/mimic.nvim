---@brief
--- Buffer detection for mimic: language, project evidence, existing
--- configuration, and tool availability.
---
--- Detection is read only. It starts no LSP clients, changes no conform or
--- nvim-lint configuration, loads no plugins on purpose, runs no processes,
--- and performs no downloads. Filesystem evidence is cached in memory and
--- refreshed by invalidation events, reload, and toggle.

local Registry = require("mimic.registry")
local Project = require("mimic.detect.project")
local Existing = require("mimic.detect.existing")
local Availability = require("mimic.detect.availability")
local Cache = require("mimic.cache")

local M = {}

M._autocmd_group = nil

local defaults = {
  current_buf = function()
    return vim.api.nvim_get_current_buf()
  end,
  filetype = function(source)
    if type(source) == "number" then
      return vim.bo[source].filetype
    end
    return ""
  end,
  buftype = function(source)
    if type(source) == "number" then
      return vim.bo[source].buftype
    end
    return ""
  end,
}

local function resolve(env)
  return vim.tbl_extend("keep", env or {}, defaults)
end

local function resolve_config(env)
  if type(env) == "table" and type(env.config) == "table" then
    return env.config
  end

  local mimic = package.loaded["mimic"]
  if type(mimic) == "table" and type(mimic.config) == "table" then
    return mimic.config
  end

  return require("mimic.config").defaults
end

---Return the registry language for a source.
---
---Also returns the filetype and a reason when there is no language.
---
---@param source integer|string
---@param env table|nil
---@return string|nil language
---@return string|nil filetype
---@return string|nil reason
function M.language(source, env)
  env = resolve(env)

  local filetype = env.filetype(source)
  if filetype == nil or filetype == "" then
    return nil, nil, "no-filetype"
  end

  local language = Registry.filetype_language(filetype)
  if language == nil then
    return nil, filetype, "unsupported-filetype"
  end

  return language, filetype, nil
end

---Detect the full context for a buffer or path.
---
---@param source integer|string|nil Buffer number or path. Defaults to the current buffer.
---@param env table|nil
---@return table
function M.context(source, env)
  env = resolve(env)
  if source == nil then
    source = env.current_buf()
  end

  local filetype = env.filetype(source)
  local context = {
    bufnr = type(source) == "number" and source or nil,
    filetype = filetype,
    language = nil,
    supported = false,
    enabled = false,
    reason = nil,
  }

  if env.buftype(source) ~= "" then
    context.reason = "buftype"
    context.existing = Existing.empty()
    context.availability = {}
    return context
  end

  local language, _, reason = M.language(source, env)
  context.language = language
  context.reason = reason
  if not language then
    context.existing = Existing.empty()
    context.availability = {}
    return context
  end

  local config = resolve_config(env)
  context.supported = true
  context.enabled = config.languages == nil or config.languages[language] ~= false

  local project = Project.analyze(source, language, env)
  context.root = project.root
  context.root_source = project.root_source
  context.git_root = project.git_root
  context.markers = project.markers
  context.files = project.files
  context.signals = project.signals
  context.packages = project.packages
  context.existing = Existing.analyze(source, language, env)
  context.availability = Availability.analyze(language, project.root, env)

  return context
end

---Clear cached evidence and reset cache statistics.
---
---Existing configuration is never cached, so this only drops project evidence
---and tool availability.
function M.clear()
  Cache.clear()
end

---Drop cached evidence without resetting cache statistics.
---
---Detection calls this from its invalidation autocmds. Omit the namespace to
---drop every cached layer.
---
---@param namespace "project"|"availability"|nil
function M.invalidate(namespace)
  Cache.invalidate(namespace)
end

---Create the autocmds that invalidate cached evidence.
---
---The cache is refreshed by Neovim events only. mimic does not start
---filesystem watchers.
function M.setup_autocmds()
  if M._autocmd_group ~= nil then
    return
  end

  M._autocmd_group = vim.api.nvim_create_augroup("mimic_cache", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = M._autocmd_group,
    callback = function()
      Cache.invalidate("project")
    end,
  })

  vim.api.nvim_create_autocmd({ "FocusGained", "VimResume" }, {
    group = M._autocmd_group,
    callback = function()
      Cache.invalidate()
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = M._autocmd_group,
    callback = function()
      Cache.invalidate()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = M._autocmd_group,
    pattern = { "LazyLoad", "LazyDone" },
    callback = function()
      Cache.invalidate("availability")
    end,
  })
end

return M
