---@brief
--- Static language and tool registry for mimic.
---
--- This module is data only. It does not start LSP clients, inspect projects,
--- configure conform, configure nvim-lint, or install tools.

local language_data = require("mimic.registry.languages")
local tool_data = require("mimic.registry.tools")

local M = {}

M.schema_version = 1
M.categories = { "lsp", "lint", "format" }
M.roles = { "language", "lint", "format" }

local category_set = {
  lsp = true,
  lint = true,
  format = true,
}

local role_set = {
  language = true,
  lint = true,
  format = true,
}

local expected_languages = {
  python = true,
  rust = true,
  c = true,
  cpp = true,
  java = true,
  javascript = true,
  typescript = true,
}

local state = nil

local function add_error(errors, fmt, ...)
  errors[#errors + 1] = fmt:format(...)
end

local function is_nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function is_string_list(value)
  if type(value) ~= "table" or #value == 0 then
    return false
  end
  for _, item in ipairs(value) do
    if not is_nonempty_string(item) then
      return false
    end
  end
  return true
end

local function is_optional_string_list(value)
  if value == nil then
    return true
  end
  if type(value) ~= "table" then
    return false
  end
  for _, item in ipairs(value) do
    if not is_nonempty_string(item) then
      return false
    end
  end
  return true
end

local function is_valid_mason(value)
  return value == nil or value == false or is_nonempty_string(value)
end

local function binding_names(category, binding)
  if category == "lsp" then
    return { binding.server }
  elseif category == "lint" then
    return { binding.linter }
  elseif category == "format" and type(binding.formatters) == "table" then
    return binding.formatters
  end
  return {}
end

local function validate_languages(errors, language_ids)
  local seen_ids = {}
  local seen_filetypes = {}
  local count = 0

  for index, language in ipairs(language_data) do
    count = count + 1
    if type(language) ~= "table" then
      add_error(errors, "language #%d is not a table", index)
    else
      local id = language.id
      if not is_nonempty_string(id) then
        add_error(errors, "language #%d has no valid id", index)
      else
        if seen_ids[id] then
          add_error(errors, "duplicate language id '%s'", id)
        else
          seen_ids[id] = true
          language_ids[id] = true
        end
        if not expected_languages[id] then
          add_error(errors, "unsupported language id '%s'", id)
        end
      end

      if not is_nonempty_string(language.label) then
        add_error(errors, "language '%s' has no label", tostring(id))
      end

      if not is_string_list(language.filetypes) then
        add_error(errors, "language '%s' must have a non-empty filetypes list", tostring(id))
      else
        for _, filetype in ipairs(language.filetypes) do
          local owner = seen_filetypes[filetype]
          if owner then
            add_error(errors, "filetype '%s' is mapped to both '%s' and '%s'", filetype, owner, tostring(id))
          else
            seen_filetypes[filetype] = tostring(id)
          end
        end
      end

      if not is_string_list(language.root_markers) then
        add_error(errors, "language '%s' must have a non-empty root_markers list", tostring(id))
      end
    end
  end

  if count ~= 7 then
    add_error(errors, "expected 7 languages, found %d", count)
  end

  for id in pairs(expected_languages) do
    if not language_ids[id] then
      add_error(errors, "missing language '%s'", id)
    end
  end
end

local function validate_binding(errors, tool_id, language_id, category, binding)
  if type(binding) ~= "table" then
    add_error(errors, "tool '%s' binding for %s/%s is not a table", tool_id, language_id, category)
    return
  end

  if not is_valid_mason(binding.mason) then
    add_error(errors, "tool '%s' binding for %s/%s has an invalid mason value", tool_id, language_id, category)
  end

  if binding.provided_by ~= nil and not is_nonempty_string(binding.provided_by) then
    add_error(errors, "tool '%s' binding for %s/%s has an invalid provided_by value", tool_id, language_id, category)
  end

  if category == "lsp" then
    if not is_nonempty_string(binding.server) then
      add_error(errors, "tool '%s' LSP binding for %s has no server", tool_id, language_id)
    end
    if not role_set[binding.role] then
      add_error(
        errors,
        "tool '%s' LSP binding for %s has invalid role '%s'",
        tool_id,
        language_id,
        tostring(binding.role)
      )
    end
    if not is_nonempty_string(binding.executable) then
      add_error(errors, "tool '%s' LSP binding for %s has no executable", tool_id, language_id)
    end

    if binding.covers ~= nil then
      if type(binding.covers) ~= "table" then
        add_error(errors, "tool '%s' LSP binding for %s has invalid covers", tool_id, language_id)
      else
        for key, value in pairs(binding.covers) do
          if key ~= "lint" and key ~= "format" then
            add_error(errors, "tool '%s' LSP binding for %s has unknown cover '%s'", tool_id, language_id, key)
          elseif type(value) ~= "boolean" then
            add_error(errors, "tool '%s' LSP cover '%s' for %s must be a boolean", tool_id, key, language_id)
          end
        end
      end
    end

    if binding.requires_plugin ~= nil and not is_nonempty_string(binding.requires_plugin) then
      add_error(errors, "tool '%s' LSP binding for %s has invalid requires_plugin", tool_id, language_id)
    end
    if binding.starter ~= nil and not is_nonempty_string(binding.starter) then
      add_error(errors, "tool '%s' LSP binding for %s has invalid starter", tool_id, language_id)
    end
    if not is_optional_string_list(binding.provider_plugins) then
      add_error(errors, "tool '%s' LSP binding for %s has invalid provider_plugins", tool_id, language_id)
    end
    if not is_optional_string_list(binding.requires_args) then
      add_error(errors, "tool '%s' LSP binding for %s has invalid requires_args", tool_id, language_id)
    end
  elseif category == "lint" then
    if not is_nonempty_string(binding.linter) then
      add_error(errors, "tool '%s' lint binding for %s has no linter", tool_id, language_id)
    end
    if not is_nonempty_string(binding.executable) then
      add_error(errors, "tool '%s' lint binding for %s has no executable", tool_id, language_id)
    end
    if binding.ignore_exitcode ~= nil and type(binding.ignore_exitcode) ~= "boolean" then
      add_error(errors, "tool '%s' lint binding for %s has invalid ignore_exitcode", tool_id, language_id)
    end
  elseif category == "format" then
    if not is_string_list(binding.formatters) then
      add_error(errors, "tool '%s' format binding for %s has no formatters", tool_id, language_id)
    end
    if not is_nonempty_string(binding.executable) then
      add_error(errors, "tool '%s' format binding for %s has no executable", tool_id, language_id)
    end
  end
end

local function validate_tools(errors, language_ids)
  local tool_ids = {}
  local seen_aliases = {}
  local binding_owners = {}
  local coverage = {}
  local has_language_lsp = {}

  for index, tool in ipairs(tool_data) do
    if type(tool) ~= "table" then
      add_error(errors, "tool #%d is not a table", index)
    else
      local id = tool.id
      if not is_nonempty_string(id) then
        add_error(errors, "tool #%d has no valid id", index)
        id = ("#%d"):format(index)
      elseif tool_ids[id] then
        add_error(errors, "duplicate tool id '%s'", id)
      else
        tool_ids[id] = true
      end

      if not is_nonempty_string(tool.label) then
        add_error(errors, "tool '%s' has no label", id)
      end
      if not is_optional_string_list(tool.config_files) then
        add_error(errors, "tool '%s' has invalid config_files", id)
      end
      if not is_optional_string_list(tool.packages) then
        add_error(errors, "tool '%s' has invalid packages", id)
      end
      if tool.requires_config ~= nil and type(tool.requires_config) ~= "boolean" then
        add_error(errors, "tool '%s' has invalid requires_config", id)
      end
      if not is_optional_string_list(tool.requires_root) then
        add_error(errors, "tool '%s' has invalid requires_root", id)
      end
      if tool.preferred_when_configured ~= nil and type(tool.preferred_when_configured) ~= "boolean" then
        add_error(errors, "tool '%s' has invalid preferred_when_configured", id)
      end
      if tool.deprecated ~= nil and type(tool.deprecated) ~= "boolean" then
        add_error(errors, "tool '%s' has invalid deprecated", id)
      end

      if tool.aliases ~= nil then
        if not is_optional_string_list(tool.aliases) then
          add_error(errors, "tool '%s' has invalid aliases", id)
        else
          for _, alias in ipairs(tool.aliases) do
            local owner = seen_aliases[alias]
            if owner then
              add_error(errors, "alias '%s' is used by both '%s' and '%s'", alias, owner, id)
            else
              seen_aliases[alias] = id
            end
          end
        end
      end

      if not is_string_list(tool.languages) then
        add_error(errors, "tool '%s' must have a non-empty languages list", id)
      else
        local seen_languages = {}
        for _, language_id in ipairs(tool.languages) do
          if seen_languages[language_id] then
            add_error(errors, "tool '%s' lists language '%s' more than once", id, language_id)
          else
            seen_languages[language_id] = true
          end
          if not language_ids[language_id] then
            add_error(errors, "tool '%s' references unknown language '%s'", id, language_id)
          end
        end
      end

      if type(tool.categories) ~= "table" then
        add_error(errors, "tool '%s' has no categories table", id)
      else
        local category_count = 0
        local language_label = type(tool.languages) == "table" and table.concat(tool.languages, ", ") or "?"
        for category, binding in pairs(tool.categories) do
          category_count = category_count + 1
          if not category_set[category] then
            add_error(errors, "tool '%s' has unknown category '%s'", id, tostring(category))
          else
            validate_binding(errors, id, language_label, category, binding)

            local priority = type(tool.priority) == "table" and tool.priority[category]
            if type(priority) ~= "number" then
              add_error(errors, "tool '%s' has no numeric priority for '%s'", id, category)
            end

            if type(binding) == "table" and is_string_list(tool.languages) then
              for _, language_id in ipairs(tool.languages) do
                coverage[language_id] = coverage[language_id] or {}
                coverage[language_id][category] = true

                if category == "lsp" then
                  if binding.role == "language" then
                    has_language_lsp[language_id] = true
                  end
                  if binding.role == "lint" or (binding.covers and binding.covers.lint) then
                    coverage[language_id].lint = true
                  end
                  if binding.role == "format" or (binding.covers and binding.covers.format) then
                    coverage[language_id].format = true
                  end
                end

                local names = binding_names(category, binding)
                for _, name in ipairs(names) do
                  binding_owners[language_id] = binding_owners[language_id] or {}
                  binding_owners[language_id][category] = binding_owners[language_id][category] or {}
                  local owner = binding_owners[language_id][category][name]
                  if owner and owner ~= id then
                    add_error(
                      errors,
                      "binding '%s' for %s/%s is provided by both '%s' and '%s'",
                      name,
                      language_id,
                      category,
                      owner,
                      id
                    )
                  else
                    binding_owners[language_id][category][name] = id
                  end
                end
              end
            end
          end
        end

        if category_count == 0 then
          add_error(errors, "tool '%s' has no categories", id)
        end

        if type(tool.priority) ~= "table" then
          add_error(errors, "tool '%s' has no priority table", id)
        else
          for category in pairs(tool.priority) do
            if not category_set[category] then
              add_error(errors, "tool '%s' has priority for unknown category '%s'", id, tostring(category))
            elseif not tool.categories[category] then
              add_error(errors, "tool '%s' has priority for missing category '%s'", id, tostring(category))
            end
          end
        end
      end
    end
  end

  for alias, owner in pairs(seen_aliases) do
    if tool_ids[alias] then
      add_error(errors, "alias '%s' on tool '%s' collides with a tool id", alias, owner)
    end
  end

  for language_id in pairs(language_ids) do
    if not has_language_lsp[language_id] then
      add_error(errors, "language '%s' has no language LSP", language_id)
    end
    if not (coverage[language_id] and coverage[language_id].lint) then
      add_error(errors, "language '%s' has no lint coverage", language_id)
    end
    if not (coverage[language_id] and coverage[language_id].format) then
      add_error(errors, "language '%s' has no format coverage", language_id)
    end
  end
end

---Validate the raw registry data.
---
---@return boolean ok
---@return string[] errors
function M.validate()
  local errors = {}
  local language_ids = {}
  validate_languages(errors, language_ids)
  validate_tools(errors, language_ids)
  return #errors == 0, errors
end

local function sort_candidates(candidates)
  table.sort(candidates, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.tool.id < b.tool.id
  end)
end

local function build()
  local registry = {
    languages = {},
    language_list = {},
    tools = {},
    tool_list = {},
    filetypes = {},
    candidates = {},
    stats = {
      languages = 0,
      tools = 0,
      candidates = 0,
    },
  }

  for _, language in ipairs(language_data) do
    registry.languages[language.id] = language
    registry.language_list[#registry.language_list + 1] = language
    registry.stats.languages = registry.stats.languages + 1
    for _, filetype in ipairs(language.filetypes) do
      registry.filetypes[filetype] = language.id
    end
  end

  for _, tool in ipairs(tool_data) do
    registry.tools[tool.id] = tool
    registry.tool_list[#registry.tool_list + 1] = tool
    registry.stats.tools = registry.stats.tools + 1

    for _, language_id in ipairs(tool.languages) do
      for category, binding in pairs(tool.categories) do
        registry.candidates[language_id] = registry.candidates[language_id] or {}
        registry.candidates[language_id][category] = registry.candidates[language_id][category] or {}
        local candidates = registry.candidates[language_id][category]
        candidates[#candidates + 1] = {
          tool = tool,
          binding = binding,
          role = binding.role,
          priority = tool.priority[category],
        }
        registry.stats.candidates = registry.stats.candidates + 1
      end
    end
  end

  for _, by_category in pairs(registry.candidates) do
    for _, candidates in pairs(by_category) do
      sort_candidates(candidates)
    end
  end

  return registry
end

local function get()
  if state == nil then
    local ok, errors = M.validate()
    if not ok then
      error("mimic registry validation failed:\n" .. table.concat(errors, "\n"), 0)
    end
    state = build()
  end
  return state
end

---Return all languages keyed by language id.
---
---@return table<string, table>
function M.languages()
  return get().languages
end

---Return one language definition.
---
---@param id string
---@return table|nil
function M.language(id)
  return get().languages[id]
end

---Return all tools keyed by tool id.
---
---@return table<string, table>
function M.tools()
  return get().tools
end

---Return one tool definition.
---
---@param id string
---@return table|nil
function M.tool(id)
  return get().tools[id]
end

---Return candidates for a language and category.
---
---Candidates are sorted by descending priority, then by tool id.
---
---@param language string
---@param category string
---@return { tool: table, binding: table, role: string|nil, priority: number }[]
function M.candidates(language, category)
  local registry = get()
  local by_category = registry.candidates[language]
  if not by_category then
    return {}
  end
  return by_category[category] or {}
end

---Return LSP candidates that can own the language LSP category.
---
---@param language string
---@return { tool: table, binding: table, role: string|nil, priority: number }[]
function M.language_servers(language)
  local servers = {}
  for _, candidate in ipairs(M.candidates(language, "lsp")) do
    if candidate.role == "language" then
      servers[#servers + 1] = candidate
    end
  end
  return servers
end

---Return the language id for a filetype.
---
---@param filetype string
---@return string|nil
function M.filetype_language(filetype)
  return get().filetypes[filetype]
end

---Return registry counts for status output.
---
---@return { languages: number, tools: number, candidates: number }
function M.stats()
  local registry = get()
  return {
    languages = registry.stats.languages,
    tools = registry.stats.tools,
    candidates = registry.stats.candidates,
  }
end

return M
