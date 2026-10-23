local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function contains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local Config = require("mimic.config")
local Registry = require("mimic.registry")

local ok, errors = Registry.validate()
eq(ok, true, "registry validates: " .. table.concat(errors, "; "))

local stats = Registry.stats()
eq(stats.languages, 7, "registry has seven languages")
eq(stats.tools >= 20, true, "registry has at least twenty tools")
eq(stats.candidates > 0, true, "registry has candidates")

local defaults = Config.resolve()
for _, category in ipairs(Registry.categories) do
  eq(defaults.categories[category], true, "config has category " .. category)
end
for language_id, language in pairs(Registry.languages()) do
  eq(defaults.languages[language_id], true, "config has language " .. language.id)
end
for language_id in pairs(defaults.languages) do
  eq(Registry.language(language_id) ~= nil, true, "registry has config language " .. language_id)
end

eq(Registry.filetype_language("python"), "python", "python filetype mapping")
eq(Registry.filetype_language("javascript"), "javascript", "javascript filetype mapping")
eq(Registry.filetype_language("javascriptreact"), "javascript", "javascriptreact filetype mapping")
eq(Registry.filetype_language("typescript"), "typescript", "typescript filetype mapping")
eq(Registry.filetype_language("typescriptreact"), "typescript", "typescriptreact filetype mapping")
eq(Registry.filetype_language("c"), "c", "c filetype mapping")
eq(Registry.filetype_language("cpp"), "cpp", "cpp filetype mapping")
eq(Registry.filetype_language("unknown"), nil, "unknown filetype has no language")

local c = Registry.language("c")
local cpp = Registry.language("cpp")
assert(c, "c language exists")
assert(cpp, "cpp language exists")
eq(c.id ~= cpp.id, true, "c and cpp are distinct language ids")
eq(contains(c.filetypes, "cpp"), false, "c does not claim cpp filetype")
eq(contains(cpp.filetypes, "c"), false, "cpp does not claim c filetype")

for _, language in pairs(Registry.languages()) do
  eq(#Registry.language_servers(language.id) > 0, true, language.id .. " has a language LSP")
end

local ts_servers = Registry.language_servers("typescript")
eq(ts_servers[1] and ts_servers[1].tool.id, "ts_ls", "ts_ls is the TypeScript fallback")
eq(ts_servers[2] and ts_servers[2].tool.id, "vtsls", "vtsls is the next TypeScript alternative")

local has_eslint_lsp = false
local has_biome_lsp = false
for _, candidate in ipairs(Registry.candidates("typescript", "lsp")) do
  if candidate.tool.id == "eslint" then
    has_eslint_lsp = true
    eq(candidate.role, "lint", "ESLint LSP owns lint")
  elseif candidate.tool.id == "biome" then
    has_biome_lsp = true
    eq(candidate.role, "lint", "Biome LSP owns lint")
  end
end
eq(has_eslint_lsp, true, "ESLint LSP is registered for TypeScript")
eq(has_biome_lsp, true, "Biome LSP is registered for TypeScript")

local ruff = Registry.tool("ruff")
assert(ruff, "ruff tool exists")
eq(contains(ruff.categories.format.formatters, "ruff_fix"), true, "ruff_fix is registered")
eq(contains(ruff.categories.format.formatters, "ruff_format"), true, "ruff_format is registered")
eq(ruff.categories.lsp.role, "lint", "Ruff LSP is a lint LSP")

local jdtls = Registry.tool("jdtls")
assert(jdtls, "jdtls tool exists")
eq(jdtls.categories.lsp.requires_plugin, "nvim-jdtls", "jdtls requires nvim-jdtls")
eq(jdtls.categories.lsp.covers.format, true, "jdtls covers Java formatting")

local checkstyle = Registry.tool("checkstyle")
assert(checkstyle, "checkstyle tool exists")
eq(checkstyle.requires_config, true, "checkstyle requires project config")

local clangd = Registry.tool("clangd")
assert(clangd, "clangd tool exists")
eq(clangd.categories.lsp.covers.lint, true, "clangd covers lint when configured")

local rust_analyzer = Registry.tool("rust_analyzer")
assert(rust_analyzer, "rust_analyzer tool exists")
eq(rust_analyzer.categories.lsp.covers.lint, true, "rust_analyzer covers lint when configured")
eq(contains(rust_analyzer.categories.lsp.provider_plugins, "rustaceanvim"), true, "rustaceanvim is a provider")

local clippy = Registry.tool("clippy")
assert(clippy, "clippy tool exists")
eq(contains(clippy.requires_root, "Cargo.toml"), true, "clippy requires a cargo manifest")
eq(clippy.categories.lint.ignore_exitcode, true, "clippy tolerates cargo's expected exit codes")

local prettier = Registry.candidates("javascript", "format")
eq(prettier[1] and prettier[1].tool.id, "prettier", "prettier is the first JavaScript formatter")

local python_lint = Registry.candidates("python", "lint")
eq(python_lint[1] and python_lint[1].tool.id, "ruff", "ruff is the first Python linter")

eq(Registry.language("unknown"), nil, "unknown language lookup returns nil")
eq(Registry.tool("unknown"), nil, "unknown tool lookup returns nil")
eq(#Registry.candidates("unknown", "lsp"), 0, "unknown language has no candidates")
eq(#Registry.candidates("python", "unknown"), 0, "unknown category has no candidates")

print("mimic registry spec: ok")
