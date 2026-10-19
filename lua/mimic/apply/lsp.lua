---@brief
--- LSP applier.
---
--- Starts the one language server the resolver selected for a buffer. It never
--- calls vim.lsp.enable, so it never globally enables a server, and it reuses
--- an already running client when the name and root match. Every client it
--- actually creates is recorded in the ledger so revert can stop it.

local Registry = require("mimic.registry")
local State = require("mimic.apply.state")

local M = {}

local provider_paths = {
  rustaceanvim = { "lua/rustaceanvim/init.lua", "lua/rustaceanvim.lua" },
  ["nvim-jdtls"] = { "lua/jdtls/init.lua", "lua/jdtls.lua" },
}

-- Servers that read python.pythonPath from settings.
local python_servers = {
  basedpyright = true,
  pyright = true,
}

local venv_dirs = { ".venv", "venv", "virtualenv" }

local function python_interpreter(root, env)
  if root == nil then
    return nil
  end
  for _, dir in ipairs(venv_dirs) do
    local path = env.joinpath(root, dir, "bin", "python")
    if env.is_file(path) then
      return path
    end
  end
  return nil
end

local function provider_available(binding, env)
  for _, plugin in ipairs(binding.provider_plugins or {}) do
    if env.has_runtime_file(provider_paths[plugin] or {}) then
      return plugin
    end
  end
  return nil
end

local function record_skip(entry, reason)
  State.add_skipped({ category = "lsp", owner = entry.owner, reason = reason })
  return { category = "lsp", owner = entry.owner, status = "skipped", reason = reason }
end

local function record_deferred(entry, reason)
  State.add_deferred({ category = "lsp", owner = entry.owner, reason = reason })
  return { category = "lsp", owner = entry.owner, status = "deferred", reason = reason }
end

local function recorded_client(id)
  for _, client in ipairs(State.clients()) do
    if client.id == id then
      return true
    end
  end
  return false
end

---Apply the lsp category of a plan.
---
---@param entry table plan.categories.lsp
---@param context table Detection context.
---@param env table Injectable Neovim access.
---@return table|nil
function M.apply(entry, context, env)
  if not entry or entry.action ~= "select" then
    return nil
  end

  local tool = Registry.tool(entry.owner)
  if tool == nil then
    return record_skip(entry, "unknown tool")
  end
  local binding = tool.categories.lsp
  if binding == nil then
    return record_skip(entry, "unknown lsp binding")
  end

  -- Servers owned by a provider plugin are left to that plugin.
  local provider = provider_available(binding, env)
  if provider then
    return record_deferred(entry, "deferred to " .. provider)
  end

  if binding.starter then
    local plugin = binding.requires_plugin
    if not plugin or env.has_runtime_file(provider_paths[plugin] or {}) then
      return record_deferred(entry, "deferred to " .. binding.starter)
    end
    return record_skip(entry, "missing " .. tostring(plugin))
  end

  local config = env.resolve_config(binding.server)
  if type(config) ~= "table" then
    return record_skip(entry, "no config for " .. tostring(binding.server))
  end

  local start_config = env.deepcopy(config)
  start_config.root_dir = context.root

  if python_servers[binding.server] then
    local interpreter = python_interpreter(context.root, env)
    if interpreter then
      start_config.settings =
        vim.tbl_deep_extend("force", start_config.settings or {}, { python = { pythonPath = interpreter } })
    end
  end

  if type(start_config.cmd) == "table" and start_config.cmd[1] and not env.executable(start_config.cmd[1]) then
    return record_skip(entry, "not runnable: " .. start_config.cmd[1])
  end

  local before = {}
  for _, client in ipairs(env.get_clients()) do
    before[client.id] = true
  end

  local ok, id = pcall(env.start, start_config, { bufnr = context.bufnr })
  if not ok then
    return record_skip(entry, "start failed: " .. tostring(id))
  end
  if id == nil then
    return record_skip(entry, "no client returned")
  end

  if before[id] then
    return { category = "lsp", owner = entry.owner, status = "reused", client = id }
  end

  -- A client that is still starting is not listed by get_clients yet, so a
  -- repeat call can return the same id. Never record the same client twice.
  if recorded_client(id) then
    return { category = "lsp", owner = entry.owner, status = "reused", client = id }
  end

  State.add_client({ id = id, name = binding.server })
  return { category = "lsp", owner = entry.owner, status = "applied", client = id }
end

return M
