---@brief
--- In-memory evidence cache for mimic.
---
--- Caches read-only filesystem evidence for project detection and tool
--- availability. Existing configuration and resolved plans are never cached,
--- so status and health always explain the current state.
---
--- Values are shared and must be treated as read-only. The cache is bounded per
--- namespace with FIFO eviction and lives only for the current Neovim session.

local M = {}

M.max_entries = 256

local stores = {}
local generation = 0

local function new_store()
  return {
    values = {},
    order = {},
    hits = 0,
    misses = 0,
    evictions = 0,
  }
end

local function get_store(namespace)
  local store = stores[namespace]
  if store == nil then
    store = new_store()
    stores[namespace] = store
  end
  return store
end

local function drop_entries(store)
  store.values = {}
  store.order = {}
end

local function snapshot(store)
  return {
    hits = store.hits,
    misses = store.misses,
    entries = #store.order,
    evictions = store.evictions,
  }
end

---Return a cached value or compute and store one.
---
---The producer runs only on a miss. A nil producer result is not cached.
---
---@param namespace string
---@param key string
---@param producer fun(): any
---@return any
function M.fetch(namespace, key, producer)
  assert(type(namespace) == "string" and namespace ~= "", "namespace is required")
  assert(type(key) == "string", "key is required")
  assert(type(producer) == "function", "producer is required")

  local store = get_store(namespace)
  local bucket = store.values[key]
  if bucket ~= nil then
    store.hits = store.hits + 1
    return bucket.value
  end

  store.misses = store.misses + 1
  local value = producer()
  if value == nil then
    return nil
  end

  if #store.order >= M.max_entries then
    local oldest = table.remove(store.order, 1)
    store.values[oldest] = nil
    store.evictions = store.evictions + 1
  end

  store.values[key] = { value = value }
  store.order[#store.order + 1] = key
  return value
end

---Drop cached entries while keeping cumulative statistics.
---
---Omit the namespace to drop every namespace.
---
---@param namespace string|nil
function M.invalidate(namespace)
  generation = generation + 1

  if namespace == nil then
    for _, store in pairs(stores) do
      drop_entries(store)
    end
    return
  end

  local store = stores[namespace]
  if store ~= nil then
    drop_entries(store)
  end
end

---Drop every entry and reset all statistics.
function M.clear()
  generation = generation + 1
  for _, store in pairs(stores) do
    drop_entries(store)
    store.hits = 0
    store.misses = 0
    store.evictions = 0
  end
end

---Return cache statistics.
---
---@return table
function M.stats()
  local namespaces = {}
  local names = {}
  local hits, misses, entries, evictions = 0, 0, 0, 0

  for name in pairs(stores) do
    names[#names + 1] = name
  end
  table.sort(names)

  for _, name in ipairs(names) do
    local item = snapshot(stores[name])
    namespaces[name] = item
    hits = hits + item.hits
    misses = misses + item.misses
    entries = entries + item.entries
    evictions = evictions + item.evictions
  end

  return {
    hits = hits,
    misses = misses,
    entries = entries,
    evictions = evictions,
    generation = generation,
    namespaces = namespaces,
  }
end

return M
