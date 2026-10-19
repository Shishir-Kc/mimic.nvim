---@brief
--- Resolution for mimic: turn a detection context into one explainable plan
--- per buffer, with a single owner per category.
---
--- Read only and pure. It starts no LSP clients, changes no conform or
--- nvim-lint configuration, calls no Mason API, and performs no downloads.
--- Applying the plan lives in mimic.apply.

local Registry = require("mimic.registry")
local Owners = require("mimic.resolve.owners")
local Score = require("mimic.resolve.score")

local M = {}

local categories = Registry.categories

local function resolve_config(config)
  if type(config) == "table" then
    return config
  end

  local mimic = package.loaded["mimic"]
  if type(mimic) == "table" and type(mimic.config) == "table" then
    return mimic.config
  end

  return require("mimic.config").defaults
end

local function category_enabled(config, category)
  return config.categories == nil or config.categories[category] ~= false
end

local function replace(providers, provider)
  for index, existing in ipairs(providers) do
    if existing.id == provider.id then
      providers[index] = provider
      return
    end
  end
  providers[#providers + 1] = provider
end

---Gather providers for a category.
---
---External bindings always count. LSP coverage only counts when that LSP is
---already active or enabled, so a newly selected server never silently absorbs
---a category it might not actually cover.
local function gather(language, category, context, existing_lsp)
  local providers = {}
  local known = {}

  for _, candidate in ipairs(Registry.candidates(language, category)) do
    local id = candidate.tool.id
    local role_ok = category ~= "lsp" or candidate.role == "language"
    if role_ok and not known[id] then
      known[id] = true
      providers[#providers + 1] = {
        id = id,
        tool = candidate.tool,
        binding = candidate.binding,
        mechanism = "external",
        category = category,
        role = candidate.role,
      }
    end
  end

  if category ~= "lsp" then
    for _, candidate in ipairs(Registry.candidates(language, "lsp")) do
      local covers = candidate.binding.covers
      local id = candidate.tool.id
      local state = existing_lsp[id]
      if type(covers) == "table" and covers[category] and state and (state.active or state.enabled) then
        known[id] = true
        replace(providers, {
          id = id,
          tool = candidate.tool,
          binding = candidate.binding,
          mechanism = "lsp",
          category = category,
          role = candidate.role,
          covers = true,
        })
      end
    end
  end

  return providers
end

local function binding_names(provider)
  if provider.category == "format" then
    return provider.binding.formatters or {}
  end
  if provider.category == "lint" and provider.binding.linter then
    return { provider.binding.linter }
  end
  return {}
end

local function configured_for(category, configured_formatters, configured_linters)
  if category == "format" then
    return configured_formatters
  end
  return configured_linters
end

local function sorted_names(set)
  local names = {}
  for name in pairs(set or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function extra_names(configured, names)
  local allowed = {}
  for _, name in ipairs(names) do
    allowed[name] = true
  end
  local extra = {}
  for name in pairs(configured) do
    if not allowed[name] then
      extra[#extra + 1] = name
    end
  end
  table.sort(extra)
  return extra
end

---Find an existing owner that mimic must not override.
local function find_existing_owner(
  category,
  providers,
  existing_lsp,
  configured_formatters,
  configured_linters,
  existing_format_lsp
)
  if category == "lsp" then
    local active, enabled, declared
    for _, provider in ipairs(providers) do
      local state = existing_lsp[provider.id]
      if state and not state.disabled then
        if state.active and not active then
          active = provider
        elseif state.enabled and not enabled then
          enabled = provider
        elseif state.configured and not declared then
          declared = provider
        end
      end
    end

    local chosen = active or enabled or declared
    if chosen then
      local reason = "already enabled"
      if chosen == active then
        reason = "already running"
      elseif chosen == declared then
        reason = "config declared"
      end
      return { provider = chosen, reason = reason, sources = (existing_lsp[chosen.id] or {}).sources or {} }
    end
    return nil
  end

  local configured = configured_for(category, configured_formatters, configured_linters)

  local matched
  local matched_name
  local matched_names
  for _, provider in ipairs(providers) do
    if provider.mechanism == "external" then
      local names = binding_names(provider)
      for _, name in ipairs(names) do
        if configured[name] then
          matched = provider
          matched_name = name
          matched_names = names
          break
        end
      end
      if matched then
        break
      end
    end
  end

  if matched then
    return {
      provider = matched,
      name = matched_name,
      reason = "already configured (" .. matched_name .. ")",
      sources = {},
      extras = extra_names(configured, matched_names),
    }
  end

  local custom = sorted_names(configured)
  if #custom > 0 then
    return {
      provider = { id = "custom", tool = { label = "custom" }, mechanism = "external" },
      name = custom[1],
      custom = true,
      custom_names = custom,
      reason = "custom configuration (" .. table.concat(custom, ", ") .. ")",
      sources = {},
      extras = {},
    }
  end

  for _, provider in ipairs(providers) do
    local state = existing_lsp[provider.id]
    if provider.mechanism == "lsp" and state and state.active and not state.disabled then
      return { provider = provider, reason = "provided by active LSP", sources = state.sources or {} }
    end
  end

  for _, provider in ipairs(providers) do
    local state = existing_lsp[provider.id]
    if provider.mechanism == "lsp" and state and state.enabled and not state.disabled then
      return { provider = provider, reason = "provided by enabled LSP", sources = state.sources or {} }
    end
  end

  -- A client that already supports formatting owns the category even when it is
  -- not a registry coverage provider, so mimic never overrides LSP formatting.
  if category == "format" and existing_format_lsp == true then
    return {
      provider = { id = "lsp", tool = { label = "LSP" }, mechanism = "lsp" },
      reason = "already provided by an active LSP",
      sources = { "active" },
    }
  end

  return nil
end

local function owner_source(context, category, owner)
  if owner.provider.mechanism == "lsp" then
    return Owners.tier(owner.sources)
  end
  local existing = context.existing
  local sources = existing and existing[category] and existing[category].sources
  if type(sources) == "table" and owner.name then
    return Owners.tier(sources[owner.name])
  end
  return nil
end

local function override_enabled(config, category)
  local value = config.override
  if value == true then
    return category == "lint" or category == "format"
  end
  if type(value) == "table" then
    return value[category] == true
  end
  return false
end

local function sort_scored(scored)
  table.sort(scored, function(a, b)
    if a.eligible ~= b.eligible then
      return a.eligible
    end
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a.id < b.id
  end)
end

local function resolve_category(
  category,
  context,
  config,
  usage,
  existing_lsp,
  configured_formatters,
  configured_linters
)
  if not category_enabled(config, category) then
    return { category = category, action = "none", reason = "category disabled", providers = {} }
  end

  local providers = gather(context.language, category, context, existing_lsp)

  local scored = {}
  for _, provider in ipairs(providers) do
    scored[#scored + 1] = Score.score(provider, context, usage)
  end
  sort_scored(scored)

  local existing_format_lsp = context.existing and context.existing.format and context.existing.format.lsp
  local owner = find_existing_owner(
    category,
    providers,
    existing_lsp,
    configured_formatters,
    configured_linters,
    existing_format_lsp
  )

  local best = nil
  for _, entry in ipairs(scored) do
    if entry.eligible then
      best = entry
      break
    end
  end

  if owner then
    local override = override_enabled(config, category)
    local replaceable = not owner.custom and #(owner.extras or {}) == 0
    local source = owner_source(context, category, owner)
    local reason = owner.reason

    if override and replaceable and best and best.id ~= owner.provider.id then
      -- An LSP coverage target can only be configured through the format
      -- fallback. Lint coverage cannot be written through nvim-lint, so the
      -- owner is kept and the plan says so.
      if best.mechanism == "external" or category == "format" then
        return {
          category = category,
          action = "override",
          owner = best.id,
          label = best.label,
          mechanism = best.mechanism,
          reason = "override: replaced " .. (owner.provider.tool.label or owner.provider.id),
          previous = {
            owner = owner.provider.id,
            label = owner.provider.tool.label or owner.provider.id,
            mechanism = owner.provider.mechanism,
            source = source,
            custom = owner.custom or false,
            extras = owner.extras or {},
          },
          providers = scored,
        }
      end
      reason = reason .. ", override target is an LSP, keeping"
    elseif override then
      if owner.custom then
        reason = reason .. ", custom not overridden"
      elseif #(owner.extras or {}) > 0 then
        reason = reason .. ", mixed not overridden"
      elseif best == nil then
        reason = reason .. ", no eligible override target"
      elseif best.id == owner.provider.id then
        reason = reason .. ", override not needed"
      end
    end

    return {
      category = category,
      action = "keep",
      owner = owner.provider.id,
      label = owner.provider.tool.label,
      mechanism = owner.provider.mechanism,
      reason = reason,
      sources = owner.sources,
      providers = scored,
    }
  end

  if best then
    return {
      category = category,
      action = "select",
      owner = best.id,
      label = best.label,
      mechanism = best.mechanism,
      reason = table.concat(best.reasons, ", "),
      providers = scored,
    }
  end

  local install = scored[1]
  return {
    category = category,
    action = "none",
    reason = "no available tool",
    install = install and { tool = install.id } or nil,
    providers = scored,
  }
end

---Turn a detection context into a plan.
---
---@param context table Detection context from mimic.detect.
---@param config table|nil Resolved mimic config. Falls back to the active config.
---@return table
function M.plan(context, config)
  config = resolve_config(config)

  local plan = {
    bufnr = context.bufnr,
    filetype = context.filetype,
    language = context.language,
    root = context.root,
    root_source = context.root_source,
    analyzed = false,
    reason = context.reason,
    mimic_enabled = config.enabled == true,
    categories = {},
  }

  local reason = context.reason
  if context.supported and context.enabled == false then
    reason = "language-disabled"
  elseif context.supported then
    reason = nil
  end

  if reason then
    plan.reason = reason
    for _, category in ipairs(categories) do
      plan.categories[category] = { category = category, action = "none", reason = reason, providers = {} }
    end
    return plan
  end

  plan.analyzed = true
  plan.reason = nil

  local usage = Score.config_usage(context.language)
  local existing_lsp = Owners.lsp(context.existing)
  local configured_formatters = Owners.formatters(context.existing)
  local configured_linters = Owners.linters(context.existing)

  for _, category in ipairs(categories) do
    plan.categories[category] =
      resolve_category(category, context, config, usage, existing_lsp, configured_formatters, configured_linters)
  end

  return plan
end

---Clear any resolver state.
---
---Resolution is stateless today. This exists so later phases with caching can
---hook into :Mimic reload without changing the public API.
function M.clear() end

return M
