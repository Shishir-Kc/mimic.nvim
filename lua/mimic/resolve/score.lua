---@brief
--- Pure scoring and eligibility for resolver candidates.
---
--- No Neovim APIs and no registry mutation. Inputs are a provider, the
--- detection context, and a config-file usage table computed once per
--- language. Every scoring decision is recorded as a human readable reason.

local Registry = require("mimic.registry")

local M = {}

M.weights = {
  dedicated_config = 60,
  shared_config = 10,
  package = 25,
  project_local = 15,
  preferred_when_configured = 40,
  deprecated = -100,
}

---A config file listed by at least this many tools is a shared manifest.
M.shared_threshold = 3

---Count how many tools list each config file for a language.
---
---@param language string
---@return table<string, number>
function M.config_usage(language)
  local usage = {}
  local seen = {}

  for _, category in ipairs(Registry.categories) do
    for _, candidate in ipairs(Registry.candidates(language, category)) do
      local tool = candidate.tool
      if not seen[tool.id] then
        seen[tool.id] = true
        for _, file in ipairs(tool.config_files or {}) do
          usage[file] = (usage[file] or 0) + 1
        end
      end
    end
  end

  return usage
end

---Describe the config files a tool has in the current project.
---
---@param tool table
---@param context table
---@param usage table<string, number>
---@return { any: boolean, dedicated: boolean, dedicated_file: string|nil, shared_file: string|nil }
function M.config_evidence(tool, context, usage)
  local evidence = {
    any = false,
    dedicated = false,
    dedicated_file = nil,
    shared_file = nil,
  }

  local files = type(context.files) == "table" and context.files or {}
  for _, file in ipairs(tool.config_files or {}) do
    if files[file] then
      evidence.any = true
      local count = usage[file] or 1
      if count < M.shared_threshold then
        if not evidence.dedicated then
          evidence.dedicated = true
          evidence.dedicated_file = file
        end
      elseif not evidence.shared_file then
        evidence.shared_file = file
      end
    end
  end

  return evidence
end

---Return the first `package.json` dependency a tool claims, if any.
---
---@param tool table
---@param context table
---@return string|nil
function M.package_evidence(tool, context)
  local packages = type(context.packages) == "table" and context.packages or {}
  for _, name in ipairs(tool.packages or {}) do
    if packages[name] then
      return name
    end
  end
  return nil
end

---Return an explainable reason when a required root marker is absent.
---
---Some tools only work inside a project that carries a specific manifest, for
---example clippy inside a cargo project. The check looks at the root markers
---recorded for the detected root; a tool config file of the same name counts
---too.
---
---@param tool table
---@param context table
---@return string|nil reason
function M.root_evidence(tool, context)
  for _, name in ipairs(tool.requires_root or {}) do
    local markers = type(context.markers) == "table" and context.markers or {}
    for _, marker in ipairs(markers) do
      if marker == name then
        return nil
      end
    end
    local files = type(context.files) == "table" and context.files or {}
    if files[name] then
      return nil
    end
  end

  local required = tool.requires_root
  if type(required) == "table" and #required > 0 then
    return "needs root " .. table.concat(required, ", ")
  end
  return nil
end

---Look up availability for a provider.
---
---@param provider table
---@param context table
---@return table|nil
function M.availability(provider, context)
  local by_tool = type(context.availability) == "table" and context.availability[provider.id] or nil
  if type(by_tool) ~= "table" then
    return nil
  end
  if provider.mechanism == "lsp" then
    return by_tool.lsp
  end
  return by_tool[provider.category]
end

---Score one provider and decide whether it is eligible.
---
---@param provider { id: string, tool: table, binding: table, mechanism: string, category: string }
---@param context table
---@param usage table<string, number>
---@return table
function M.score(provider, context, usage)
  local tool = provider.tool
  local binding = provider.binding
  local category = provider.category
  local reasons = {}

  local priority = tool.priority and tool.priority[category] or 0
  local score = priority
  reasons[#reasons + 1] = "priority " .. tostring(priority)

  local available = M.availability(provider, context)
  local eligible = true

  if not (available and available.available) then
    eligible = false
    reasons[#reasons + 1] = "not installed"
  end

  if tool.deprecated then
    eligible = false
    reasons[#reasons + 1] = "deprecated"
  end

  if binding.requires_plugin and not (available and available.plugin_available == true) then
    eligible = false
    reasons[#reasons + 1] = "missing " .. binding.requires_plugin
  end

  local config = M.config_evidence(tool, context, usage)
  if tool.requires_config and not config.any then
    eligible = false
    reasons[#reasons + 1] = "needs config"
  end

  local root_reason = M.root_evidence(tool, context)
  if root_reason then
    eligible = false
    reasons[#reasons + 1] = root_reason
  end

  if config.dedicated then
    score = score + M.weights.dedicated_config
    reasons[#reasons + 1] = "config " .. config.dedicated_file
  elseif config.any then
    score = score + M.weights.shared_config
    reasons[#reasons + 1] = "manifest " .. tostring(config.shared_file)
  end

  local package = M.package_evidence(tool, context)
  if package then
    score = score + M.weights.package
    reasons[#reasons + 1] = "package " .. package
  end

  if available and available.source == "project" then
    score = score + M.weights.project_local
    reasons[#reasons + 1] = "project local binary"
  end

  if tool.preferred_when_configured and config.dedicated then
    score = score + M.weights.preferred_when_configured
    reasons[#reasons + 1] = "preferred when configured"
  end

  if tool.deprecated then
    score = score + M.weights.deprecated
  end

  return {
    id = provider.id,
    label = tool.label,
    mechanism = provider.mechanism,
    category = category,
    priority = priority,
    score = score,
    eligible = eligible,
    availability = available and available.source or nil,
    reasons = reasons,
  }
end

return M
