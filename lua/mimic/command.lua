---@brief
--- :Mimic subcommand dispatch.

local M = {}

local subcommands = {
  status = true,
  toggle = true,
  reload = true,
  install = true,
}

local function ensure_setup()
  local mimic = require("mimic")
  if not mimic._did_setup then
    mimic.setup()
  end
  return mimic
end

local function notify(message, level)
  vim.notify("mimic: " .. message, level or vim.log.levels.INFO, { title = "mimic" })
end

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function join_or_none(map)
  local keys = sorted_keys(map)
  if #keys == 0 then
    return "none"
  end
  return table.concat(keys, ",")
end

local function override_label(override)
  if type(override) ~= "table" then
    return "off"
  end
  local names = {}
  for _, category in ipairs({ "lsp", "lint", "format" }) do
    if override[category] == true then
      names[#names + 1] = category
    end
  end
  if #names == 0 then
    return "off"
  end
  return table.concat(names, ",")
end

local function context_lines(context)
  local lines = {}
  if context.language then
    local root = context.root and (" root " .. context.root) or " root none"
    local source = context.root_source and (" [" .. context.root_source .. "]") or ""
    lines[#lines + 1] = ("Buffer: %s (%s)%s%s"):format(context.language, context.filetype or "?", root, source)
    local existing = context.existing
    lines[#lines + 1] = ("  existing: lsp active=%s enabled=%s; format=%s; lint=%s"):format(
      join_or_none(existing.lsp.active),
      join_or_none(existing.lsp.enabled),
      join_or_none(existing.format.configured),
      join_or_none(existing.lint.configured)
    )
  else
    lines[#lines + 1] = ("Buffer: %s"):format(context.reason or "unsupported")
  end
  return lines
end

local function plan_lines(plan)
  local lines = { "Plan:" }
  if not plan.analyzed then
    lines[#lines + 1] = ("  inactive (%s)"):format(plan.reason or "not applicable")
    return lines
  end

  for _, category in ipairs({ "lsp", "lint", "format" }) do
    local entry = plan.categories[category]
    if entry then
      if entry.action == "override" then
        local name = entry.label or entry.owner or "?"
        local previous = entry.previous and entry.previous.label or "?"
        lines[#lines + 1] = ("  %s: override %s over %s (%s)"):format(category, name, previous, entry.reason or "")
      elseif entry.action == "keep" or entry.action == "select" then
        local name = entry.label or entry.owner or "?"
        lines[#lines + 1] = ("  %s: %s %s (%s)"):format(category, entry.action, name, entry.reason or "")
      elseif entry.install and entry.install.tool then
        lines[#lines + 1] = ("  %s: none (%s, install %s)"):format(category, entry.reason or "", entry.install.tool)
      else
        lines[#lines + 1] = ("  %s: none (%s)"):format(category, entry.reason or "")
      end
    end
  end
  return lines
end

local function install_lines(proposal)
  local lines = {}
  local packages = {}
  for _, package in ipairs(proposal.packages or {}) do
    local categories = table.concat(package.categories or {}, ",")
    if categories ~= "" then
      packages[#packages + 1] = ("%s (%s)"):format(package.name, categories)
    else
      packages[#packages + 1] = package.name
    end
  end
  if #packages > 0 then
    lines[#lines + 1] = "  mason: " .. table.concat(packages, ", ")
  end

  local manual = {}
  for _, item in ipairs(proposal.manual or {}) do
    manual[#manual + 1] = ("%s: %s"):format(item.label or item.tool, item.reason)
  end
  if #manual > 0 then
    lines[#lines + 1] = "  manual: " .. table.concat(manual, ", ")
  end

  return lines
end

local function applied_lines(applied)
  local lines = { "Applied:" }
  local clients = applied.clients or {}
  if #clients == 0 then
    lines[#lines + 1] = "  clients: none started by mimic"
  else
    for _, client in ipairs(clients) do
      lines[#lines + 1] = ("  client: %s (id %d)"):format(client.name, client.id)
    end
  end

  local format_edits = applied.format_edits or {}
  if #format_edits > 0 then
    local names = {}
    for _, edit in ipairs(format_edits) do
      local label = edit.ft
      if edit.replaced and edit.replaced.label then
        label = ("%s over %s"):format(label, edit.replaced.label)
      end
      names[#names + 1] = label
    end
    lines[#lines + 1] = ("  format: %s"):format(table.concat(names, ", "))
  end

  local lint_edits = applied.lint_edits or {}
  if #lint_edits > 0 then
    local parts = {}
    for _, edit in ipairs(lint_edits) do
      local text = ("%s (%s)"):format(edit.ft, table.concat(edit.names or {}, ","))
      if edit.replaced and edit.replaced.label then
        text = text .. " over " .. edit.replaced.label
      end
      parts[#parts + 1] = text
    end
    lines[#lines + 1] = ("  lint: %s"):format(table.concat(parts, ", "))
  end

  if applied.trigger then
    lines[#lines + 1] = "  lint trigger: created by mimic"
  end

  for _, item in ipairs(applied.deferred or {}) do
    lines[#lines + 1] = ("  deferred %s %s: %s"):format(item.category, item.owner, item.reason)
  end
  for _, item in ipairs(applied.skipped or {}) do
    lines[#lines + 1] = ("  skipped %s %s: %s"):format(item.category, item.owner, item.reason)
  end

  return lines
end

---Show the usage line.
function M.usage()
  notify("usage: :Mimic {status|toggle|reload|install}", vim.log.levels.WARN)
end

---Print setup state, integration availability, registry counts, and cache stats.
function M.status()
  local mimic = ensure_setup()
  local status = mimic.status()

  local lines = {
    ("mimic %s"):format(status.version),
    ("Neovim %s"):format(status.neovim),
    ("Setup: %s"):format(status.did_setup and "yes" or "no"),
    ("Enabled: %s"):format(status.enabled and "yes" or "no"),
    ("Override: %s"):format(override_label(status.override)),
    ("Install: %s"):format(status.install and status.install.mode or "?"),
    "",
    "Integrations:",
  }

  for _, item in ipairs(status.integrations) do
    local suffix = item.optional and " (optional)" or ""
    lines[#lines + 1] = ("  %s: %s%s"):format(item.name, item.available and "yes" or "no", suffix)
  end

  lines[#lines + 1] = ""
  if status.registry then
    lines[#lines + 1] = ("Registry: %d languages, %d tools, %d candidates"):format(
      status.registry.languages,
      status.registry.tools,
      status.registry.candidates
    )
  elseif status.registry_error then
    lines[#lines + 1] = "Registry: invalid (run :checkhealth mimic)"
  end

  if status.cache then
    lines[#lines + 1] = ("Cache: %d hits, %d misses, %d entries"):format(
      status.cache.hits,
      status.cache.misses,
      status.cache.entries
    )
  elseif status.cache_error then
    lines[#lines + 1] = "Cache: unavailable (run :checkhealth mimic)"
  end

  if status.context then
    lines[#lines + 1] = ""
    for _, line in ipairs(context_lines(status.context)) do
      lines[#lines + 1] = line
    end
  elseif status.context_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Buffer: detection failed (run :checkhealth mimic)"
  end

  if status.plan then
    lines[#lines + 1] = ""
    for _, line in ipairs(plan_lines(status.plan)) do
      lines[#lines + 1] = line
    end
  elseif status.plan_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Plan: resolution failed (run :checkhealth mimic)"
  end

  if status.install_proposal then
    local planned = install_lines(status.install_proposal)
    if #planned > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Install plan:"
      for _, line in ipairs(planned) do
        lines[#lines + 1] = line
      end
    end
  elseif status.install_proposal_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Install plan: unavailable (run :checkhealth mimic)"
  end

  if status.applied then
    lines[#lines + 1] = ""
    for _, line in ipairs(applied_lines(status.applied)) do
      lines[#lines + 1] = line
    end
  elseif status.applied_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Applied: applier failed (run :checkhealth mimic)"
  end

  if status.java_missing_jdtls then
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      'Java: nvim-jdtls is not installed. Add "mfussenegger/nvim-jdtls" to your plugin spec to use Java support.'
  end

  notify(table.concat(lines, "\n"))
end

---Toggle mimic for this session only.
function M.toggle()
  local mimic = ensure_setup()
  local enabled = mimic.toggle()
  notify(("session %s"):format(enabled and "enabled" or "disabled"))
end

---Reset state and reapply the original options.
function M.reload()
  local mimic = ensure_setup()
  mimic.reload()
  notify("configuration reloaded")
end

---Install missing Mason packages for the current buffer.
function M.install()
  local mimic = ensure_setup()
  require("mimic.install").start(mimic.config)
end

---Dispatch a subcommand from :Mimic.
---
---@param args string|nil
function M.dispatch(args)
  local sub = vim.trim(args or ""):lower()
  if sub == "" then
    M.usage()
    return
  end

  local handler = M[sub]
  if not subcommands[sub] or type(handler) ~= "function" then
    notify(("unknown subcommand '%s'"):format(sub), vim.log.levels.WARN)
    M.usage()
    return
  end

  handler()
end

---Completion for :Mimic.
---
---@param arglead string
---@return string[]
function M.complete(arglead)
  local matches = {}
  for name in pairs(subcommands) do
    if name:find("^" .. vim.pesc(arglead)) then
      matches[#matches + 1] = name
    end
  end
  table.sort(matches)
  return matches
end

return M
