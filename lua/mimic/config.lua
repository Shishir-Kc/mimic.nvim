---@brief
--- Configuration defaults and validation for mimic.
---
--- This module is intentionally free of Neovim APIs so the pure parts can be
--- tested with plain Lua. Warnings are returned to the caller instead of being
--- emitted here.

local M = {}

M.defaults = {
  enabled = true,
  override = {
    lsp = false,
    lint = false,
    format = false,
  },
  install = { mode = "ask" },
  completion = {
    enabled = true,
    autotrigger = true,
  },
  languages = {
    python = true,
    rust = true,
    c = true,
    cpp = true,
    java = true,
    javascript = true,
    typescript = true,
  },
  categories = {
    lsp = true,
    lint = true,
    format = true,
  },
  log_level = "warn",
}

local install_modes = {
  ask = true,
  never = true,
  auto = true,
}

local log_levels = {
  trace = true,
  debug = true,
  info = true,
  warn = true,
  error = true,
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

local function warn(warnings, fmt, ...)
  warnings[#warnings + 1] = fmt:format(...)
end

local function apply_boolean(resolved, opts, key, warnings)
  local value = opts[key]
  if value == nil then
    return
  end
  if type(value) ~= "boolean" then
    warn(warnings, "option '%s' must be a boolean, keeping %s", key, tostring(resolved[key]))
    return
  end
  resolved[key] = value
end

local function apply_boolean_map(resolved, user, label, warnings)
  if user == nil then
    return
  end
  if type(user) ~= "table" then
    warn(warnings, "'%ss' must be a table, keeping defaults", label)
    return
  end

  local unknown = {}
  for key, value in pairs(user) do
    local name = tostring(key)
    if resolved[key] == nil then
      unknown[#unknown + 1] = name
    elseif type(value) ~= "boolean" then
      warn(warnings, "%s '%s' must be a boolean, keeping %s", label, name, tostring(resolved[key]))
    else
      resolved[key] = value
    end
  end

  if #unknown > 0 then
    table.sort(unknown)
    warn(warnings, "unknown %s%s %s ignored", label, #unknown == 1 and "" or "s", table.concat(unknown, ", "))
  end
end

local override_categories = { "lsp", "lint", "format" }
local override_known = { lsp = true, lint = true, format = true }

local function apply_override(resolved, value, warnings)
  if value == nil then
    return
  end

  if value == true then
    resolved.override.lint = true
    resolved.override.format = true
    return
  end

  if value == false then
    resolved.override.lsp = false
    resolved.override.lint = false
    resolved.override.format = false
    return
  end

  if type(value) ~= "table" then
    warn(warnings, "option 'override' must be a boolean or a table, keeping it off")
    return
  end

  local unknown = {}
  for key in pairs(value) do
    local name = tostring(key)
    if not override_known[name] then
      unknown[#unknown + 1] = name
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    warn(warnings, "unknown override categor%s %s ignored", #unknown == 1 and "y" or "ies", table.concat(unknown, ", "))
  end

  for _, category in ipairs(override_categories) do
    local enabled = value[category]
    if enabled ~= nil then
      if type(enabled) ~= "boolean" then
        warn(warnings, "override.%s must be a boolean, keeping false", category)
      elseif category == "lsp" and enabled == true then
        warn(warnings, "override.lsp is not implemented yet, ignoring")
      else
        resolved.override[category] = enabled
      end
    end
  end
end

local completion_keys = { enabled = true, autotrigger = true }

local function apply_completion(resolved, value, warnings)
  if value == nil then
    return
  end

  if type(value) ~= "table" then
    warn(warnings, "option 'completion' must be a table, keeping defaults")
    return
  end

  local unknown = {}
  for key in pairs(value) do
    local name = tostring(key)
    if not completion_keys[name] then
      unknown[#unknown + 1] = name
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    warn(warnings, "unknown completion option%s %s ignored", #unknown == 1 and "" or "s", table.concat(unknown, ", "))
  end

  for _, key in ipairs({ "enabled", "autotrigger" }) do
    local enabled = value[key]
    if enabled ~= nil then
      if type(enabled) ~= "boolean" then
        warn(warnings, "completion.%s must be a boolean, keeping %s", key, tostring(resolved.completion[key]))
      else
        resolved.completion[key] = enabled
      end
    end
  end
end

---Resolve user options against the defaults.
---
---Unknown keys are ignored and reported once through the returned warnings.
---Invalid values keep their default and are reported the same way.
---
---@param user table|nil
---@return table resolved
---@return string[] warnings
function M.resolve(user)
  local resolved = copy(M.defaults)
  local warnings = {}

  if user == nil then
    return resolved, warnings
  end

  if type(user) ~= "table" then
    warn(warnings, "setup options must be a table, using defaults")
    return resolved, warnings
  end

  local unknown = {}
  for key in pairs(user) do
    if M.defaults[key] == nil then
      unknown[#unknown + 1] = tostring(key)
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    warn(warnings, "unknown option%s %s ignored", #unknown == 1 and "" or "s", table.concat(unknown, ", "))
  end

  apply_boolean(resolved, user, "enabled", warnings)
  apply_override(resolved, user.override, warnings)
  apply_completion(resolved, user.completion, warnings)

  if user.install ~= nil then
    if type(user.install) ~= "table" then
      warn(warnings, "option 'install' must be a table, keeping defaults")
    else
      local unknown_install = {}
      for key in pairs(user.install) do
        if key ~= "mode" then
          unknown_install[#unknown_install + 1] = tostring(key)
        end
      end
      if #unknown_install > 0 then
        table.sort(unknown_install)
        warn(
          warnings,
          "unknown install option%s %s ignored",
          #unknown_install == 1 and "" or "s",
          table.concat(unknown_install, ", ")
        )
      end

      local mode = user.install.mode
      if mode ~= nil then
        if type(mode) ~= "string" or not install_modes[mode] then
          warn(warnings, "install.mode must be 'ask', 'never', or 'auto', keeping '%s'", resolved.install.mode)
        else
          resolved.install.mode = mode
        end
      end
    end
  end

  apply_boolean_map(resolved.languages, user.languages, "language", warnings)
  apply_boolean_map(resolved.categories, user.categories, "category", warnings)

  if user.log_level ~= nil then
    if type(user.log_level) ~= "string" or not log_levels[user.log_level] then
      warn(warnings, "log_level must be trace, debug, info, warn, or error, keeping '%s'", resolved.log_level)
    else
      resolved.log_level = user.log_level
    end
  end

  return resolved, warnings
end

return M
