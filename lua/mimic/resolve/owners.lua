---@brief
--- Existing-owner detection and source classification for the resolver.
---
--- Read only and pure. It turns the detection existing-configuration record
--- into the answers the resolver needs: which tools are active or enabled,
--- which tools already have configuration, and how much authority each source
--- carries.

local M = {}

local user_tags = {
  active = true,
  declared = true,
  runtime = true,
}

---Classify a list of source tags.
---
---"user" covers active, declared, and runtime, because runtime enablement
---cannot tell a user config apart from a LazyVim extra. "lazyvim" means the
---only evidence is a LazyVim declaration.
---
---@param tags string[]|nil
---@return string|nil tier
function M.tier(tags)
  if type(tags) ~= "table" then
    return nil
  end

  local has_lazyvim = false
  for _, tag in ipairs(tags) do
    if user_tags[tag] then
      return "user"
    end
    if tag == "lazyvim" then
      has_lazyvim = true
    end
  end

  if has_lazyvim then
    return "lazyvim"
  end
  return nil
end

local function record(state, id)
  state[id] = state[id]
    or {
      active = false,
      enabled = false,
      disabled = false,
      configured = false,
      tier = nil,
      sources = {},
    }
  return state[id]
end

---Summarize the existing LSP configuration per tool id.
---
---@param existing table
---@return table<string, { active: boolean, enabled: boolean, disabled: boolean, configured: boolean, tier: string|nil, sources: string[] }>
function M.lsp(existing)
  local state = {}
  local lsp = type(existing) == "table" and existing.lsp or nil
  if type(lsp) ~= "table" then
    return state
  end

  for id in pairs(lsp.active or {}) do
    record(state, id).active = true
  end
  for id in pairs(lsp.enabled or {}) do
    record(state, id).enabled = true
  end
  for id in pairs(lsp.disabled or {}) do
    record(state, id).disabled = true
  end
  for id in pairs(lsp.configured or {}) do
    record(state, id).configured = true
  end
  for id, tags in pairs(lsp.sources or {}) do
    local entry = record(state, id)
    entry.tier = M.tier(tags)
    entry.sources = tags
  end

  return state
end

---Return the set of configured formatter names.
---
---@param existing table
---@return table<string, boolean>
function M.formatters(existing)
  local names = {}
  local format = type(existing) == "table" and existing.format or nil
  if type(format) == "table" and type(format.configured) == "table" then
    for name in pairs(format.configured) do
      names[name] = true
    end
  end
  return names
end

---Return the set of configured linter names.
---
---@param existing table
---@return table<string, boolean>
function M.linters(existing)
  local names = {}
  local lint = type(existing) == "table" and existing.lint or nil
  if type(lint) == "table" and type(lint.configured) == "table" then
    for name in pairs(lint.configured) do
      names[name] = true
    end
  end
  return names
end

return M
