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
  local patched = M.patch_definition(binding, env)
  State.upsert_lint_edit({
    ft = filetype,
    previous = current,
    names = names,
    value = { binding.linter },
    replaced = replaced,
    patched = patched,
  })
  map[filetype] = names

  if patched then
    return {
      category = "lint",
      owner = entry.owner,
      status = "applied",
      linters = names,
      replaced = entry.previous,
      patched = patched,
    }
  end

  return { category = "lint", owner = entry.owner, status = "applied", linters = names, replaced = entry.previous }
end

---Tolerate a linter's expected nonzero exit codes.
---
---Some linters exit nonzero under normal conditions. For example cargo
---clippy exits 101 whenever the crate fails to build, which is a normal
---editing state. nvim-lint warns on any nonzero exit unless the definition
---sets `ignore_exitcode`. When the binding asks for it, mimic writes that
---field into the loaded definition, but never over a value the user already
---set. The write is recorded so revert restores the previous value.
---
---@param binding table lint binding from the registry
---@param env table injectable Neovim access
---@return table|nil patch summary, or nil when the binding does not ask
function M.patch_definition(binding, env)
  if binding.ignore_exitcode ~= true then
    return nil
  end

  local name = binding.linter
  local lint = load_lint(env)
  if lint == nil or type(lint.linters) ~= "table" then
    return { name = name, field = "ignore_exitcode", status = "skipped", reason = "definition not available" }
  end

  local definition = lint.linters[name]
  if type(definition) ~= "table" then
    return { name = name, field = "ignore_exitcode", status = "skipped", reason = "definition not found" }
  end

  local previous = definition.ignore_exitcode
  if previous ~= nil then
    return { name = name, field = "ignore_exitcode", status = "kept", reason = "user config" }
  end

  definition.ignore_exitcode = true
  State.upsert_def_edit({ name = name, field = "ignore_exitcode", previous = nil })
  return { name = name, field = "ignore_exitcode", status = "applied" }
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
