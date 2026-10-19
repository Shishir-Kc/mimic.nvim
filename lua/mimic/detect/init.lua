---@brief
--- Buffer detection for mimic: language, project evidence, existing
--- configuration, and tool availability.
---
--- Detection is read only. It starts no LSP clients, changes no conform or
--- nvim-lint configuration, loads no plugins on purpose, runs no processes,
--- and performs no downloads. Results are computed on demand.

local Registry = require("mimic.registry")
local Project = require("mimic.detect.project")
local Existing = require("mimic.detect.existing")
local Availability = require("mimic.detect.availability")

local M = {}

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

---Clear any detection state.
---
---Detection is stateless today. This exists so later phases with caching can
---hook into :Mimic reload without changing the public API.
function M.clear() end

return M
