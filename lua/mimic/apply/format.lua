---@brief
--- Formatter applier.
---
--- Fills conform only when the filetype has no formatter entry. With override
--- enabled by the plan, it replaces the entry and records the previous value
--- so revert can restore it exactly. When the resolver owns formatting through
--- an LSP, it writes the LSP fallback instead of an external formatter.

local Registry = require("mimic.registry")
local State = require("mimic.apply.state")

local M = {}

local function load_conform(env)
  local module = env.loaded("conform")
  if module ~= nil then
    return module
  end
  local ok, required = pcall(env.require_module, "conform")
  if not ok or type(required) ~= "table" then
    return nil
  end
  return required
end

local function unset(value)
  return type(value) ~= "table" or next(value) == nil
end

---Apply the format category of a plan.
---
---@param entry table plan.categories.format
---@param context table Detection context.
---@param env table Injectable Neovim access.
---@return table|nil
function M.apply(entry, context, env)
  if not entry or (entry.action ~= "select" and entry.action ~= "override") then
    return nil
  end

  local conform = load_conform(env)
  if conform == nil then
    State.add_deferred({ category = "format", owner = entry.owner, reason = "conform not available" })
    return { category = "format", owner = entry.owner, status = "deferred", reason = "conform not available" }
  end

  local map = conform.formatters_by_ft
  if type(map) ~= "table" then
    State.add_deferred({ category = "format", owner = entry.owner, reason = "conform is not set up" })
    return { category = "format", owner = entry.owner, status = "deferred", reason = "conform is not set up" }
  end

  local filetype = context.filetype
  local current = map[filetype]
  local override = entry.action == "override"

  if override then
    local recorded = State.format_value(filetype)
    local deep_equal = env.deep_equal or vim.deep_equal
    if recorded ~= nil and deep_equal(current, recorded) then
      return { category = "format", owner = entry.owner, status = "skipped", reason = "already overridden by mimic" }
    end
  elseif not unset(current) then
    return { category = "format", owner = entry.owner, status = "skipped", reason = "formatters already set" }
  end

  local value
  if entry.mechanism == "lsp" then
    value = { lsp_format = "fallback" }
  else
    local tool = Registry.tool(entry.owner)
    local binding = tool and tool.categories.format
    if binding == nil then
      return { category = "format", owner = entry.owner, status = "skipped", reason = "unknown format binding" }
    end
    value = env.deepcopy(binding.formatters)
  end

  local replaced = entry.previous and { owner = entry.previous.owner, label = entry.previous.label } or nil
  State.upsert_format_edit({
    ft = filetype,
    previous = current,
    value = env.deepcopy(value),
    replaced = replaced,
  })
  map[filetype] = value

  return {
    category = "format",
    owner = entry.owner,
    status = "applied",
    formatters = value,
    replaced = entry.previous,
  }
end

return M
