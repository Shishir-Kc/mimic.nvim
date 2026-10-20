---@brief
--- Build a read-only install proposal for a resolved plan.
---
--- The proposal answers one question: which missing Mason packages would fill
--- the categories that currently have no owner? It does not load Mason, refresh
--- a registry, or download anything. It reuses the resolver with a copied
--- availability table where every Mason-backed binding is marked available, so
--- tools that cover more than one category are proposed only once.

local Registry = require("mimic.registry")
local Resolve = require("mimic.resolve")

local M = {}

local provided_by_labels = {
  llvm = "LLVM",
  pip = "pip",
  project = "project dependencies",
  rustup = "rustup",
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

local function simulated_availability(language, availability)
  local simulated = copy(availability or {})

  for _, category in ipairs(Registry.categories) do
    for _, candidate in ipairs(Registry.candidates(language, category)) do
      local binding = candidate.binding
      if binding.mason then
        local by_tool = simulated[candidate.tool.id]
        if by_tool == nil then
          by_tool = {}
          simulated[candidate.tool.id] = by_tool
        end

        local record = by_tool[category]
        if record == nil then
          record = {
            available = false,
            executable = binding.executable,
          }
          by_tool[category] = record
        end

        record.available = true
        record.source = "mason"
        record.mason = binding.mason
        if binding.provided_by then
          record.provided_by = binding.provided_by
        end
        if binding.requires_plugin then
          record.requires_plugin = binding.requires_plugin
        end
      end
    end
  end

  return simulated
end

local function add_package(packages, by_name, category, tool, binding)
  local package = by_name[binding.mason]
  if package == nil then
    package = {
      categories = {},
      name = binding.mason,
      tools = {},
    }
    by_name[binding.mason] = package
    packages[#packages + 1] = package
  end

  local tool_seen = false
  for _, id in ipairs(package.tools) do
    if id == tool.id then
      tool_seen = true
      break
    end
  end
  if not tool_seen then
    package.tools[#package.tools + 1] = tool.id
  end

  for _, name in ipairs(package.categories) do
    if name == category then
      return
    end
  end
  package.categories[#package.categories + 1] = category
end

local function manual_hint(category, entry)
  local provider = entry.providers and entry.providers[1]
  if provider == nil then
    return nil
  end

  local tool = Registry.tool(provider.id)
  local binding = tool and tool.categories and tool.categories[category] or nil
  local reason

  if tool and tool.requires_config then
    reason = "requires project config"
  elseif binding and binding.requires_plugin then
    reason = "requires " .. binding.requires_plugin
  elseif tool and tool.deprecated then
    reason = "deprecated"
  elseif binding and binding.provided_by then
    reason = "provided by " .. (provided_by_labels[binding.provided_by] or binding.provided_by)
  elseif binding and binding.mason then
    reason = "requires project config or a plugin"
  else
    reason = "install manually"
  end

  return {
    category = category,
    label = (tool and tool.label) or provider.label or provider.id,
    reason = reason,
    tool = provider.id,
  }
end

local category_order = {
  lsp = 1,
  lint = 2,
  format = 3,
}

local function sort_manual(manual)
  table.sort(manual, function(a, b)
    local left = category_order[a.category] or 99
    local right = category_order[b.category] or 99
    if left ~= right then
      return left < right
    end
    return a.tool < b.tool
  end)
end

local function sort_packages(packages)
  table.sort(packages, function(a, b)
    return a.name < b.name
  end)
  for _, package in ipairs(packages) do
    table.sort(package.tools)
  end
end

---Build an install proposal.
---
---@param context table Detection context.
---@param plan table Resolved plan.
---@param config table|nil Resolved config.
---@return { language: string|nil, mode: string, packages: table[], manual: table[] }
function M.build(context, plan, config)
  local mode = config and config.install and config.install.mode or "ask"
  local result = {
    language = type(context) == "table" and context.language or nil,
    manual = {},
    mode = mode,
    packages = {},
  }

  if
    type(context) ~= "table"
    or not context.supported
    or not context.language
    or context.enabled == false
    or type(plan) ~= "table"
    or not plan.analyzed
  then
    return result
  end

  local simulated = {}
  for key, value in pairs(context) do
    simulated[key] = value
  end
  simulated.availability = simulated_availability(context.language, context.availability)

  local next_plan = Resolve.plan(simulated, config)
  if type(next_plan) ~= "table" or type(next_plan.categories) ~= "table" then
    return result
  end

  local by_name = {}
  local seen_manual = {}

  for _, category in ipairs(Registry.categories) do
    local current = plan.categories[category]
    if current and current.action == "none" and current.reason ~= "category disabled" then
      local next_entry = next_plan.categories[category]
      local selected = next_entry and (next_entry.action == "select" or next_entry.action == "override")

      if selected then
        local tool = Registry.tool(next_entry.owner)
        local binding = tool and tool.categories and tool.categories[category] or nil
        if binding and binding.mason then
          add_package(result.packages, by_name, category, tool, binding)
        else
          local hint = manual_hint(category, current)
          if hint then
            local key = category .. "\0" .. hint.tool
            if not seen_manual[key] then
              seen_manual[key] = true
              result.manual[#result.manual + 1] = hint
            end
          end
        end
      else
        local hint = manual_hint(category, current)
        if hint then
          local key = category .. "\0" .. hint.tool
          if not seen_manual[key] then
            seen_manual[key] = true
            result.manual[#result.manual + 1] = hint
          end
        end
      end
    end
  end

  sort_manual(result.manual)
  sort_packages(result.packages)

  return result
end

return M
