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

---Completion settings from the passed config.
---
---Falls back to the module defaults so callers that do not thread config keep
---the zero-option behavior.
---
---@param config table|nil
---@return table
local function completion_settings(config)
  if type(config) == "table" and type(config.completion) == "table" then
    return config.completion
  end
  return require("mimic.config").defaults.completion
end

---True when the client advertises textDocument/completion.
local function provides_completion(client_id, env)
  local client = env.get_client_by_id(client_id)
  local caps = type(client) == "table" and client.server_capabilities or nil
  if type(caps) ~= "table" then
    return false
  end
  return caps.completionProvider ~= nil
end

---Tool id that owns a server name, falling back to the server name itself.
---
---Completion records made at attach time no longer carry the plan entry, so
---the owner is looked up from the registry by server name instead.
---
---@param name string|integer client server name, or the bare client id
---@return string
local function owner_for(name)
  if type(name) ~= "string" then
    return tostring(name)
  end
  for _, tool in ipairs(Registry.tools()) do
    local binding = tool.categories and tool.categories.lsp
    if binding and binding.server == name then
      return tool.id
    end
  end
  return name
end

---Fill in builtin completion for a client mimic owns, at attach time.
---
---Completion rendering normally belongs to a dedicated engine such as
---nvim-cmp or blink.cmp. Detection reports any installed engine and mimic
---defers to it. Without one, mimic enables Neovim's builtin completion for the
---client it owns. The enablement is recorded so revert can undo it.
---
---This runs on LspAttach for two reasons. Capabilities are only known after
---the initialize round-trip, so the capability check is meaningful at attach
---time, not while a buffer is being applied. Attaching also names the buffer,
---which makes enablement per run because the same client can serve many
---buffers. Only clients in the applier ledger are touched.
---
---@param bufnr integer buffer the client attached to
---@param client_id integer
---@param config table|nil Resolved config.
---@param env table Injectable Neovim access.
---@return table|nil result status record, or nil when the client is not mimic's
function M.enable_completion(bufnr, client_id, config, env)
  local settings = completion_settings(config)
  if settings.enabled ~= true then
    return { status = "skipped", reason = "completion disabled" }
  end

  local owned = false
  for _, client in ipairs(State.clients()) do
    if client.id == client_id then
      owned = true
      break
    end
  end
  if not owned then
    return nil
  end

  local client = env.get_client_by_id(client_id)
  local owner = owner_for(client and client.name or client_id)

  local engine = env.completion_engine()
  if type(engine) == "table" and engine.engine then
    local reason = engine.source == "installed" and "engine installed (" .. engine.engine .. ")"
      or "engine present (" .. engine.engine .. ")"
    State.add_skipped({ category = "completion", owner = owner, reason = reason })
    return { status = "skipped", reason = reason }
  end

  if not env.completion_available() then
    local reason = "builtin completion not available"
    State.add_deferred({ category = "completion", owner = owner, reason = reason })
    return { status = "deferred", reason = reason }
  end

  if not provides_completion(client_id, env) then
    local reason = "server provides no completion"
    State.add_skipped({ category = "completion", owner = owner, reason = reason })
    return { status = "skipped", reason = reason }
  end

  local opts = { autotrigger = settings.autotrigger == true }
  if not env.completion_enable(client_id, bufnr, opts) then
    local reason = "completion could not be enabled"
    State.add_skipped({ category = "completion", owner = owner, reason = reason })
    return { status = "skipped", reason = reason }
  end

  State.upsert_completion_edit({ client_id = client_id, bufnr = bufnr, autotrigger = opts.autotrigger })
  return { status = "enabled", autotrigger = opts.autotrigger }
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
---Completion is deliberately not filled in here: right after a start the
---client is still initializing and its capabilities are unknown, so builtin
---completion is enabled from LspAttach instead.
---
---@param entry table plan.categories.lsp
---@param context table Detection context.
---@param env table Injectable Neovim access.
---@param config table|nil Resolved config.
---@return table|nil
function M.apply(entry, context, env, config)
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

  local server_config = env.resolve_config(binding.server)
  if type(server_config) ~= "table" then
    return record_skip(entry, "no config for " .. tostring(binding.server))
  end

  local start_config = env.deepcopy(server_config)
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
