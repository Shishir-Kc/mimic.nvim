---@brief
--- Linter applier.
---
--- Fills nvim-lint only when the filetype has no linter entry. With override
--- enabled by the plan, it replaces the entry and records the previous value
--- so revert can restore it exactly. It also creates a trigger autocmd when no
--- other nvim-lint trigger is present, so linting works with zero options.

local Registry = require("mimic.registry")
local State = require("mimic.apply.state")

local M = {}

local function load_lint(env)
  local module = env.loaded("lint")
  if module ~= nil then
    return module
  end
  local ok, required = pcall(env.require_module, "lint")
  if not ok or type(required) ~= "table" then
    return nil
  end
  return required
end

---Apply the lint category of a plan.
---
---@param entry table plan.categories.lint
---@param context table Detection context.
---@param env table Injectable Neovim access.
---@return table|nil
function M.apply(entry, context, env)
  if not entry or (entry.action ~= "select" and entry.action ~= "override") then
    return nil
  end

  local lint = load_lint(env)
  if lint == nil then
    State.add_deferred({ category = "lint", owner = entry.owner, reason = "nvim-lint not available" })
    return { category = "lint", owner = entry.owner, status = "deferred", reason = "nvim-lint not available" }
  end

  local map = lint.linters_by_ft
  if type(map) ~= "table" then
    State.add_deferred({ category = "lint", owner = entry.owner, reason = "nvim-lint is not set up" })
    return { category = "lint", owner = entry.owner, status = "deferred", reason = "nvim-lint is not set up" }
  end

  local tool = Registry.tool(entry.owner)
  local binding = tool and tool.categories.lint
  if binding == nil then
    return { category = "lint", owner = entry.owner, status = "skipped", reason = "unknown lint binding" }
  end

  local filetype = context.filetype
  local current = map[filetype]
  local override = entry.action == "override"

  if override then
    local recorded = State.lint_value(filetype)
    local deep_equal = env.deep_equal or vim.deep_equal
    if recorded ~= nil and deep_equal(current, recorded) then
      return { category = "lint", owner = entry.owner, status = "skipped", reason = "already overridden by mimic" }
    end
  elseif type(current) == "table" and #current > 0 then
    return { category = "lint", owner = entry.owner, status = "skipped", reason = "linters already set" }
  end

  local names = { binding.linter }
  local replaced = entry.previous and { owner = entry.previous.owner, label = entry.previous.label } or nil
  State.upsert_lint_edit({
    ft = filetype,
    previous = current,
    names = names,
    value = { binding.linter },
    replaced = replaced,
  })
  map[filetype] = names

  return { category = "lint", owner = entry.owner, status = "applied", linters = names, replaced = entry.previous }
end

---Create a lint trigger when no nvim-lint trigger exists.
---
---@param env table Injectable Neovim access.
---@return boolean created
function M.ensure_trigger(env)
  if State.trigger_created() then
    return false
  end
  if env.has_augroup("nvim-lint") then
    return false
  end
  env.create_lint_trigger()
  State.set_trigger(true)
  return true
end

return M
