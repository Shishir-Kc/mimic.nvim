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
