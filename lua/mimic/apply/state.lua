---@brief
--- Ownership ledger for the applier.
---
--- Records exactly what mimic changed so revert can undo only that. Everything
--- here is plain Lua and can be inspected or reset without Neovim APIs, which
--- keeps the applier testable.

local M = {}

local state

local function fresh()
  return {
    clients = {},
    format_edits = {},
    lint_edits = {},
    def_edits = {},
    completion_edits = {},
    deferred = {},
    skipped = {},
    trigger = false,
  }
end

function M.reset()
  state = fresh()
end

M.reset()

---@param entry { id: integer, name: string }
function M.add_client(entry)
  state.clients[#state.clients + 1] = entry
end

---@return { id: integer, name: string }[]
function M.clients()
  return state.clients
end

---@param entry { ft: string, previous: table|nil, value: table, replaced: table|nil }
function M.upsert_format_edit(entry)
  for index, edit in ipairs(state.format_edits) do
    if edit.ft == entry.ft then
      state.format_edits[index] = entry
      return
    end
  end
  state.format_edits[#state.format_edits + 1] = entry
end

---@return { ft: string, previous: table|nil, value: table, replaced: table|nil }[]
function M.format_edits()
  return state.format_edits
end

---Return the formatter value mimic wrote for a filetype.
---
---@param filetype string
---@return table|nil
function M.format_value(filetype)
  for _, edit in ipairs(state.format_edits) do
    if edit.ft == filetype then
      return edit.value
    end
  end
  return nil
end

---@param entry { ft: string, previous: table|nil, names: string[], value: table, replaced: table|nil }
function M.upsert_lint_edit(entry)
  for index, edit in ipairs(state.lint_edits) do
    if edit.ft == entry.ft then
      state.lint_edits[index] = entry
      return
    end
  end
  state.lint_edits[#state.lint_edits + 1] = entry
end

---@return { ft: string, previous: table|nil, names: string[], value: table, replaced: table|nil }[]
function M.lint_edits()
  return state.lint_edits
end

---Return the linter value mimic wrote for a filetype.
---
---@param filetype string
---@return table|nil
function M.lint_value(filetype)
  for _, edit in ipairs(state.lint_edits) do
    if edit.ft == filetype then
      return edit.value
    end
  end
  return nil
end

---Return the linter names mimic owns for a filetype.
---
---@param filetype string
---@return string[]
function M.lint_names(filetype)
  for _, edit in ipairs(state.lint_edits) do
    if edit.ft == filetype then
      return edit.names
    end
  end
  return {}
end

---Record a linter-definition field mimic set.
---
---Definition edits cover the loaded nvim-lint linter table, for example a
---clippy definition that must tolerate cargo's expected nonzero exit codes.
---Revert restores the exact previous field value.
---
---@param entry { name: string, field: string, previous: any }
function M.upsert_def_edit(entry)
  for index, edit in ipairs(state.def_edits) do
    if edit.name == entry.name and edit.field == entry.field then
      state.def_edits[index] = entry
      return
    end
  end
  state.def_edits[#state.def_edits + 1] = entry
end

---Return the linter-definition fields mimic set.
---
---@return { name: string, field: string, previous: any }[]
function M.def_edits()
  return state.def_edits
end

---Record builtin completion mimic enabled.
---
---Completion enablement is per client id and buffer number so revert can turn
---off exactly what mimic turned on. The same pair is recorded only once.
---
---@param entry { client_id: integer, bufnr: integer, autotrigger: boolean }
function M.upsert_completion_edit(entry)
  for index, edit in ipairs(state.completion_edits) do
    if edit.client_id == entry.client_id and edit.bufnr == entry.bufnr then
      state.completion_edits[index] = entry
      return
    end
  end
  state.completion_edits[#state.completion_edits + 1] = entry
end

---@return { client_id: integer, bufnr: integer, autotrigger: boolean }[]
function M.completion_edits()
  return state.completion_edits
end

---@param entry { category: string, owner: string, reason: string }
function M.add_deferred(entry)
  state.deferred[#state.deferred + 1] = entry
end

---@return { category: string, owner: string, reason: string }[]
function M.deferred()
  return state.deferred
end

---@param entry { category: string, owner: string, reason: string }
function M.add_skipped(entry)
  state.skipped[#state.skipped + 1] = entry
end

---@return { category: string, owner: string, reason: string }[]
function M.skipped()
  return state.skipped
end

---@param value boolean
function M.set_trigger(value)
  state.trigger = value == true
end

---@return boolean
function M.trigger_created()
  return state.trigger
end

---Return a copy of the ledger for status and health output.
---
---@return table
function M.snapshot()
  return vim.deepcopy(state)
end

return M
