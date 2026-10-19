---@brief
--- Project evidence for a buffer: root discovery, markers, config files, and a
--- few package manager signals.
---
--- This module is read only. It never starts processes, never writes files,
--- and never mutates plugin configuration.

local Registry = require("mimic.registry")

local M = {}

local defaults = {
  path_of = function(source)
    if type(source) == "number" then
      return vim.api.nvim_buf_get_name(source)
    end
    return source or ""
  end,
  root = function(source, markers)
    return vim.fs.root(source, markers)
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
  readfile = function(path)
    return vim.fn.readfile(path)
  end,
  decode = function(text)
    return vim.json.decode(text)
  end,
}

local function resolve(env)
  return vim.tbl_extend("keep", env or {}, defaults)
end

local function exists(env, path)
  return env.is_file(path) or env.is_dir(path)
end

local function collect_signals(env, root)
  local function at(name)
    return exists(env, env.join(root, name))
  end

  return {
    python_venv = at(".venv") or at("venv") or at("virtualenv"),
    python_poetry = at("poetry.lock"),
    python_uv = at("uv.lock"),
    python_pipenv = at("Pipfile"),
    python_requirements = at("requirements.txt"),
    rust_cargo_lock = at("Cargo.lock"),
    clang_compile_commands = at("compile_commands.json"),
    clang_compile_flags = at("compile_flags.txt"),
    java_maven = at("pom.xml"),
    java_gradle = at("build.gradle") or at("build.gradle.kts"),
    java_maven_wrapper = at("mvnw"),
    java_gradle_wrapper = at("gradlew"),
    js_package_lock = at("package-lock.json"),
    js_yarn_lock = at("yarn.lock"),
    js_pnpm_lock = at("pnpm-lock.yaml"),
  }
end

local function read_packages(env, root)
  local path = env.join(root, "package.json")
  if not env.is_file(path) then
    return {}
  end

  local ok, lines = pcall(env.readfile, path)
  if not ok or type(lines) ~= "table" then
    return {}
  end

  local decoded_ok, decoded = pcall(env.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return {}
  end

  local packages = {}
  for _, field in ipairs({ "dependencies", "devDependencies", "peerDependencies", "optionalDependencies" }) do
    local deps = decoded[field]
    if type(deps) == "table" then
      for name in pairs(deps) do
        if type(name) == "string" then
          packages[name] = true
        end
      end
    end
  end
  return packages
end

local function empty()
  return {
    root = nil,
    root_source = nil,
    git_root = nil,
    markers = {},
    files = {},
    signals = {},
    packages = {},
  }
end

---Analyze project evidence for a source.
---
---The source may be a buffer number or a file path.
---
---@param source integer|string
---@param language string
---@param env table|nil
---@return table
function M.analyze(source, language, env)
  env = resolve(env)

  local language_def = Registry.language(language)
  if not language_def then
    return empty()
  end

  local path = env.path_of(source)
  if path == nil or path == "" then
    return empty()
  end

  local root = env.root(source, { language_def.root_markers, ".git" })
  if not root then
    return empty()
  end

  local result = {
    root = root,
    root_source = nil,
    git_root = env.root(source, ".git"),
    markers = {},
    files = {},
    signals = {},
    packages = {},
  }

  for _, name in ipairs(language_def.root_markers) do
    if exists(env, env.join(root, name)) then
      result.markers[#result.markers + 1] = name
    end
  end

  if result.markers[1] then
    result.root_source = result.markers[1]
  elseif exists(env, env.join(root, ".git")) then
    result.root_source = ".git"
  else
    result.root_source = "unknown"
  end

  for _, category in ipairs(Registry.categories) do
    for _, candidate in ipairs(Registry.candidates(language, category)) do
      for _, name in ipairs(candidate.tool.config_files or {}) do
        if result.files[name] == nil then
          local file = env.join(root, name)
          if exists(env, file) then
            result.files[name] = file
          end
        end
      end
    end
  end

  result.signals = collect_signals(env, root)
  result.packages = read_packages(env, root)
  return result
end

return M
