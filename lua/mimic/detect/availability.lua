---@brief
--- Tool availability evidence for a language.
---
--- Availability is checked through the filesystem only: project local binaries,
--- PATH lookups, and the Mason package directory. No process is started, no
--- package manager is loaded, and no network access happens.

local Registry = require("mimic.registry")

local M = {}

local project_dirs = {
  "node_modules/.bin",
  ".venv/bin",
  "venv/bin",
}

local plugin_paths = {
  ["nvim-jdtls"] = { "lua/jdtls/init.lua", "lua/jdtls.lua" },
  ["rustaceanvim"] = { "lua/rustaceanvim/init.lua", "lua/rustaceanvim.lua" },
}

local defaults = {
  executable = function(exe)
    return vim.fn.executable(exe) == 1
  end,
  is_file = function(path)
    return vim.fn.filereadable(path) == 1
  end,
  is_dir = function(path)
    return vim.fn.isdirectory(path) == 1
  end,
  join = function(...)
    return vim.fs.joinpath(...)
  end,
  mason_dir = function()
    return vim.env.MASON or (vim.fn.stdpath("data") .. "/mason")
  end,
  has_runtime_file = function(paths)
    for _, path in ipairs(paths) do
      if #vim.api.nvim_get_runtime_file(path, false) > 0 then
        return true
      end
    end
    return false
  end,
}

local function resolve(env)
  return vim.tbl_extend("keep", env or {}, defaults)
end

local function check(binding, root, env)
  local record = {
    executable = binding.executable,
    available = false,
    source = nil,
    path = nil,
  }

  if root ~= nil then
    for _, dir in ipairs(project_dirs) do
      local path = env.join(root, dir, binding.executable)
      if env.is_file(path) then
        record.available = true
        record.source = "project"
        record.path = path
        break
      end
    end
  end

  if not record.available and env.executable(binding.executable) then
    record.available = true
    record.source = "path"
  end

  if not record.available and binding.mason and env.is_dir(env.join(env.mason_dir(), "packages", binding.mason)) then
    record.available = true
    record.source = "mason"
    record.path = env.join(env.mason_dir(), "packages", binding.mason)
  end

  if binding.mason then
    record.mason = binding.mason
  end
  if binding.provided_by then
    record.provided_by = binding.provided_by
  end
  if binding.requires_plugin then
    record.requires_plugin = binding.requires_plugin
    record.plugin_available = env.has_runtime_file(plugin_paths[binding.requires_plugin] or {})
  end

  return record
end

---Check availability for every candidate of a language.
---
---The result is keyed by tool id and then by category.
---
---@param language string
---@param root string|nil
---@param env table|nil
---@return table
function M.analyze(language, root, env)
  env = resolve(env)
  local result = {}

  for _, category in ipairs(Registry.categories) do
    for _, candidate in ipairs(Registry.candidates(language, category)) do
      local id = candidate.tool.id
      result[id] = result[id] or {}
      result[id][category] = check(candidate.binding, root, env)
    end
  end

  return result
end

return M
