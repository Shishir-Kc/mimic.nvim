-- Phase 7 cache spec.
--
-- Run with:
--   NVIM_APPNAME=mimic-test nvim --headless -u tests/minimal_init.lua -l tests/cache_spec.lua

local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Cache = require("mimic.cache")
local Detect = require("mimic.detect")
local Project = require("mimic.detect.project")
local Availability = require("mimic.detect.availability")

Cache.clear()

-- Cache basics --------------------------------------------------------------

local calls = 0
local first = Cache.fetch("test", "alpha", function()
  calls = calls + 1
  return { value = 1 }
end)
local second = Cache.fetch("test", "alpha", function()
  calls = calls + 1
  return { value = 2 }
end)

eq(calls, 1, "producer runs once for a repeated key")
eq(first, second, "a cache hit returns the stored value")

local nil_calls = 0
eq(
  Cache.fetch("test", "nil", function()
    nil_calls = nil_calls + 1
    return nil
  end),
  nil,
  "a nil producer result is returned"
)
eq(
  Cache.fetch("test", "nil", function()
    nil_calls = nil_calls + 1
    return nil
  end),
  nil,
  "a nil producer result is still nil on the second call"
)
eq(nil_calls, 2, "nil producer results are not cached")

local false_calls = 0
eq(
  Cache.fetch("test", "false", function()
    false_calls = false_calls + 1
    return false
  end),
  false,
  "false is a valid cached value"
)
Cache.fetch("test", "false", function()
  false_calls = false_calls + 1
  return true
end)
eq(false_calls, 1, "false is cached instead of treated as a miss")

local stats = Cache.stats()
eq(stats.namespaces.test.hits, 2, "cache counts hits")
eq(stats.namespaces.test.misses, 4, "cache counts misses and nil results")
eq(stats.namespaces.test.entries, 2, "cache counts entries")

local before_invalidate = Cache.stats()
Cache.invalidate("test")
local after_invalidate = Cache.stats()
eq(after_invalidate.namespaces.test.entries, 0, "invalidate drops entries")
eq(after_invalidate.hits, before_invalidate.hits, "invalidate keeps hit statistics")
eq(after_invalidate.misses, before_invalidate.misses, "invalidate keeps miss statistics")
eq(after_invalidate.generation > before_invalidate.generation, true, "invalidate advances the generation")

Cache.clear()
local after_clear = Cache.stats()
eq(after_clear.hits, 0, "clear resets hits")
eq(after_clear.misses, 0, "clear resets misses")
eq(after_clear.entries, 0, "clear resets entries")
eq(after_clear.evictions, 0, "clear resets evictions")

-- Eviction ------------------------------------------------------------------

local old_max = Cache.max_entries
Cache.max_entries = 2
Cache.clear()
Cache.fetch("test", "one", function()
  return 1
end)
Cache.fetch("test", "two", function()
  return 2
end)
Cache.fetch("test", "three", function()
  return 3
end)

stats = Cache.stats()
eq(stats.namespaces.test.entries, 2, "the cache respects max_entries")
eq(stats.namespaces.test.evictions, 1, "the cache records FIFO evictions")

local recomputed = false
Cache.fetch("test", "one", function()
  recomputed = true
  return 1
end)
eq(recomputed, true, "the oldest entry was evicted")
Cache.max_entries = old_max
Cache.clear()

-- Project evidence ----------------------------------------------------------

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.writefile({ "[tool.ruff]" }, root .. "/pyproject.toml")
vim.fn.writefile({ "requests" }, root .. "/requirements.txt")
vim.fn.writefile({ '{"devDependencies":{"typescript":"^5"}}' }, root .. "/package.json")

local path_calls = 0
local project_env = {
  path_of = function(source)
    return source
  end,
  is_file = function(path)
    path_calls = path_calls + 1
    return vim.fn.filereadable(path) == 1
  end,
  is_dir = function(path)
    path_calls = path_calls + 1
    return vim.fn.isdirectory(path) == 1
  end,
}

local project_path = root .. "/src/main.py"
local project_first = Project.analyze(project_path, "python", project_env)
local calls_after_first = path_calls
eq(project_first.root, root, "project root detected")
eq(project_first.files["pyproject.toml"] ~= nil, true, "project config file detected")

local project_second = Project.analyze(project_path, "python", project_env)
eq(path_calls, calls_after_first, "second project analysis used the cache")
eq(project_second.root, project_first.root, "cached project root matches")
eq(project_second.markers, project_first.markers, "cached project markers are shared")

Cache.invalidate("project")
local calls_before_refresh = path_calls
Project.analyze(project_path, "python", project_env)
eq(path_calls > calls_before_refresh, true, "project invalidation forces a refresh")

-- Tool availability ---------------------------------------------------------

local executable_calls = 0
local availability_env = {
  executable = function(exe)
    executable_calls = executable_calls + 1
    return exe == "ruff"
  end,
  is_file = function()
    return false
  end,
  is_dir = function()
    return false
  end,
  mason_dir = function()
    return "/definitely/missing/mason"
  end,
  has_runtime_file = function()
    return false
  end,
}

local availability_first = Availability.analyze("python", root, availability_env)
local availability_calls = executable_calls
eq(availability_first.ruff.lint.available, true, "availability finds ruff")

local availability_second = Availability.analyze("python", root, availability_env)
eq(executable_calls, availability_calls, "second availability analysis used the cache")
eq(availability_second.ruff.lint.available, true, "cached availability keeps the result")

Cache.invalidate("availability")
local calls_before_availability_refresh = executable_calls
Availability.analyze("python", root, availability_env)
eq(executable_calls > calls_before_availability_refresh, true, "availability invalidation forces a refresh")

-- Autocmd invalidation ------------------------------------------------------

Detect.setup_autocmds()
local cache_autocmds = vim.api.nvim_get_autocmds({ group = "mimic_cache" })
eq(#cache_autocmds >= 4, true, "setup creates cache invalidation autocmds")

Cache.clear()
Project.analyze(project_path, "python", project_env)
Availability.analyze("python", root, availability_env)
eq(Cache.stats().entries > 0, true, "cache is populated before invalidation")

local before_focus = Cache.stats()
vim.api.nvim_exec_autocmds("FocusGained", {})
local after_focus = Cache.stats()
eq(after_focus.entries, 0, "FocusGained drops all cached evidence")
eq(after_focus.hits, before_focus.hits, "FocusGained keeps hit statistics")

Cache.clear()
Project.analyze(project_path, "python", project_env)
Availability.analyze("python", root, availability_env)
vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad" })
local after_lazy = Cache.stats()
eq(after_lazy.namespaces.project.entries > 0, true, "LazyLoad keeps project evidence")
eq(after_lazy.namespaces.availability.entries, 0, "LazyLoad drops availability")

Availability.analyze("python", root, availability_env)
vim.api.nvim_exec_autocmds("BufWritePost", {})
local after_write = Cache.stats()
eq(after_write.namespaces.project.entries, 0, "BufWritePost drops project evidence")
eq(after_write.namespaces.availability.entries > 0, true, "BufWritePost keeps availability")

Cache.clear()
Project.analyze(project_path, "python", project_env)
Availability.analyze("python", root, availability_env)
vim.api.nvim_exec_autocmds("DirChanged", {})
eq(Cache.stats().entries, 0, "DirChanged drops all cached evidence")

Cache.fetch("test", "clear", function()
  return true
end)
Detect.clear()
local after_detect_clear = Cache.stats()
eq(after_detect_clear.entries, 0, "Detect.clear drops entries")
eq(after_detect_clear.hits, 0, "Detect.clear resets hits")
eq(after_detect_clear.misses, 0, "Detect.clear resets misses")

vim.fn.delete(root, "rf")
print("mimic cache spec: ok")
