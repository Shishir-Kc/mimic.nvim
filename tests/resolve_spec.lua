local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Resolve = require("mimic.resolve")
local Score = require("mimic.resolve.score")
local Registry = require("mimic.registry")
local Existing = require("mimic.detect.existing")

local function avail(source)
  return { available = true, source = source or "mason", executable = "tool" }
end

local function existing_with(mutate)
  local existing = Existing.empty()
  mutate(existing)
  return existing
end

local function context(language, opts)
  opts = opts or {}
  return {
    bufnr = 1,
    filetype = opts.filetype or language,
    language = language,
    supported = true,
    enabled = opts.enabled ~= false,
    root = opts.root or "/proj",
    root_source = opts.root_source or "marker",
    markers = opts.markers or {},
    files = opts.files or {},
    signals = opts.signals or {},
    packages = opts.packages or {},
    existing = opts.existing or Existing.empty(),
    availability = opts.availability or {},
  }
end

local function python_availability()
  return {
    basedpyright = { lsp = avail() },
    pyright = { lsp = avail() },
    ruff = { lsp = avail(), lint = avail(), format = avail() },
    ruff_lsp = { lsp = avail() },
    flake8 = { lint = avail() },
    pylint = { lint = avail() },
    mypy = { lint = avail() },
    black = { format = avail() },
  }
end

local function provider_by_id(entry, id)
  for _, provider in ipairs(entry.providers or {}) do
    if provider.id == id then
      return provider
    end
  end
  return nil
end

-- Bare Python: select the highest priority tools per category ----------------

local plan = Resolve.plan(context("python", { availability = python_availability() }))
eq(plan.analyzed, true, "python plan is analyzed")
eq(plan.categories.lsp.action, "select", "python lsp is selected")
eq(plan.categories.lsp.owner, "basedpyright", "basedpyright owns the python LSP")
eq(plan.categories.lint.owner, "ruff", "ruff owns python lint")
eq(plan.categories.format.owner, "ruff", "ruff owns python format")
eq(plan.categories.lsp.providers[1].eligible, true, "eligible providers sort first")
eq(plan.categories.lsp.providers[1].id, "basedpyright", "best eligible provider is first")

local ruff_lsp = provider_by_id(plan.categories.lsp, "ruff_lsp")
eq(ruff_lsp, nil, "non-language LSPs do not compete for the language LSP")

local ruff_lsp_tool = Registry.tool("ruff_lsp")
local ruff_lsp_score = Score.score({
  id = "ruff_lsp",
  tool = ruff_lsp_tool,
  binding = ruff_lsp_tool.categories.lsp,
  mechanism = "external",
  category = "lsp",
}, context("python", { availability = python_availability() }), Score.config_usage("python"))
eq(ruff_lsp_score.eligible, false, "deprecated tool is ineligible")

-- Dedicated versus shared config --------------------------------------------

local dedicated = Resolve.plan(context("python", {
  availability = python_availability(),
  files = { ["ruff.toml"] = "/proj/ruff.toml" },
}))
eq(dedicated.categories.lint.owner, "ruff", "dedicated config keeps ruff on lint")
eq(dedicated.categories.lint.reason:find("ruff.toml") ~= nil, true, "reason names the dedicated config")

local shared = Resolve.plan(context("python", {
  availability = python_availability(),
  files = { ["pyproject.toml"] = "/proj/pyproject.toml" },
}))
eq(shared.categories.lint.owner, "ruff", "shared manifest does not change the linter")
eq(shared.categories.lint.reason:find("manifest") ~= nil, true, "shared manifest is reported as a manifest")

-- Existing owners are kept ---------------------------------------------------

local active = existing_with(function(existing)
  existing.lsp.active = { basedpyright = true }
  existing.lsp.sources = { basedpyright = { "active" } }
end)
local kept = Resolve.plan(context("python", { availability = python_availability(), existing = active }))
eq(kept.categories.lsp.action, "keep", "active LSP is kept")
eq(kept.categories.lsp.owner, "basedpyright", "active LSP owner")
eq(kept.categories.lsp.reason, "already running", "active LSP reason")

local configured = existing_with(function(existing)
  existing.lint.configured = { ruff = true }
  existing.lint.sources = { ruff = { "runtime" } }
end)
local kept_lint = Resolve.plan(context("python", { availability = python_availability(), existing = configured }))
eq(kept_lint.categories.lint.action, "keep", "configured linter is kept")
eq(kept_lint.categories.lint.owner, "ruff", "configured linter owner")

-- Override mode --------------------------------------------------------------

local Config = require("mimic.config")

local function override_config(value)
  return Config.resolve({ override = value })
end

local configured_format = existing_with(function(existing)
  existing.format.configured = { black = true }
  existing.format.sources = { black = { "runtime" } }
end)
local kept_format =
  Resolve.plan(context("python", { availability = python_availability(), existing = configured_format }))
eq(kept_format.categories.format.action, "keep", "configured formatter is kept without override")
eq(kept_format.categories.format.owner, "black", "configured formatter owner without override")

local override_format = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = configured_format,
  }),
  override_config({ format = true })
)
eq(override_format.categories.format.action, "override", "override replaces the formatter")
eq(override_format.categories.format.owner, "ruff", "the best formatter wins the override")
eq(override_format.categories.format.previous.owner, "black", "previous formatter is recorded")
eq(override_format.categories.format.previous.label, "Black", "previous formatter label is recorded")
eq(override_format.categories.format.previous.source, "user", "previous formatter source tier is recorded")
eq(override_format.categories.lint.action, "select", "format-only override leaves lint alone")

local configured_flake8 = existing_with(function(existing)
  existing.lint.configured = { flake8 = true }
  existing.lint.sources = { flake8 = { "runtime" } }
end)
local override_lint = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = configured_flake8,
  }),
  override_config({ lint = true })
)
eq(override_lint.categories.lint.action, "override", "override replaces the linter")
eq(override_lint.categories.lint.owner, "ruff", "ruff wins the lint override")
eq(override_lint.categories.lint.previous.owner, "flake8", "previous linter is recorded")

local same_owner = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = configured,
  }),
  override_config({ lint = true })
)
eq(same_owner.categories.lint.action, "keep", "override keeps the best owner")
eq(same_owner.categories.lint.reason:find("override not needed") ~= nil, true, "override not needed is explained")

local custom_format = existing_with(function(existing)
  existing.format.configured = { my_formatter = true }
  existing.format.sources = { my_formatter = { "runtime" } }
end)
local custom_plan = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = custom_format,
  }),
  override_config({ format = true })
)
eq(custom_plan.categories.format.action, "keep", "custom formatter is kept")
eq(custom_plan.categories.format.owner, "custom", "custom formatter owner is reported")
eq(custom_plan.categories.format.reason:find("custom not overridden") ~= nil, true, "custom keep is explained")

local mixed_format = existing_with(function(existing)
  existing.format.configured = { black = true, my_formatter = true }
  existing.format.sources = { black = { "runtime" }, my_formatter = { "runtime" } }
end)
local mixed_plan = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = mixed_format,
  }),
  override_config({ format = true })
)
eq(mixed_plan.categories.format.action, "keep", "mixed formatter entry is kept")
eq(mixed_plan.categories.format.reason:find("mixed not overridden") ~= nil, true, "mixed keep is explained")

local configured_both = existing_with(function(existing)
  existing.lint.configured = { flake8 = true }
  existing.lint.sources = { flake8 = { "runtime" } }
  existing.format.configured = { black = true }
  existing.format.sources = { black = { "runtime" } }
end)
local lint_only = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = configured_both,
  }),
  override_config({ lint = true })
)
eq(lint_only.categories.lint.action, "override", "lint override applies")
eq(lint_only.categories.format.action, "keep", "format stays filled without an override")

local no_target = Resolve.plan(
  context("python", {
    availability = { basedpyright = { lsp = avail() } },
    existing = configured_format,
  }),
  override_config({ format = true })
)
eq(no_target.categories.format.action, "keep", "override keeps the owner without an eligible target")
eq(
  no_target.categories.format.reason:find("no eligible override target") ~= nil,
  true,
  "missing override target is explained"
)

local lsp_with_override = Resolve.plan(
  context("python", {
    availability = python_availability(),
    existing = active,
  }),
  override_config({ lint = true, format = true })
)
eq(lsp_with_override.categories.lsp.action, "keep", "override never replaces the LSP")
eq(lsp_with_override.categories.lsp.owner, "basedpyright", "active LSP still owns lsp")

-- An enabled lint LSP is already the best owner, so override keeps it.
local ruff_lsp_lint = existing_with(function(existing)
  existing.lsp.enabled = { ruff = true }
  existing.lsp.sources = { ruff = { "runtime" } }
end)
local lsp_lint_override = Resolve.plan(
  context("python", { availability = python_availability(), existing = ruff_lsp_lint }),
  override_config({ lint = true })
)
eq(lsp_lint_override.categories.lint.action, "keep", "an enabled lint LSP is kept")
eq(lsp_lint_override.categories.lint.owner, "ruff", "the enabled lint LSP keeps the category")
eq(
  lsp_lint_override.categories.lint.reason:find("override not needed") ~= nil,
  true,
  "the enabled LSP override is explained"
)

-- Lint coverage cannot be written through nvim-lint, so when the best target
-- is an active lint LSP, the external owner is kept and the plan explains it.
local flake8_with_ruff_lsp = existing_with(function(existing)
  existing.lint.configured = { flake8 = true }
  existing.lint.sources = { flake8 = { "runtime" } }
  existing.lsp.enabled = { ruff = true }
  existing.lsp.sources = { ruff = { "runtime" } }
end)
local lsp_lint_target = Resolve.plan(
  context("python", { availability = python_availability(), existing = flake8_with_ruff_lsp }),
  override_config({ lint = true })
)
eq(lsp_lint_target.categories.lint.action, "keep", "a lint LSP target keeps the external owner")
eq(lsp_lint_target.categories.lint.owner, "flake8", "the external lint owner is kept")
eq(
  lsp_lint_target.categories.lint.reason:find("override target is an LSP") ~= nil,
  true,
  "the unconfigurable lint LSP target is explained"
)

-- Java plugin and config gating ---------------------------------------------

local java_missing = {
  jdtls = { lsp = { available = true, source = "mason", requires_plugin = "nvim-jdtls", plugin_available = false } },
  checkstyle = { lint = avail() },
  google_java_format = { format = avail() },
}
local no_plugin = Resolve.plan(context("java", { availability = java_missing }))
eq(no_plugin.categories.lsp.action, "none", "jdtls ineligible without nvim-jdtls")
eq(no_plugin.categories.lsp.install.tool, "jdtls", "install hint names jdtls")

local java_ready = {
  jdtls = { lsp = { available = true, source = "mason", requires_plugin = "nvim-jdtls", plugin_available = true } },
  checkstyle = { lint = avail() },
  google_java_format = { format = avail() },
}
local with_plugin = Resolve.plan(context("java", { availability = java_ready }))
eq(with_plugin.categories.lsp.owner, "jdtls", "jdtls selected with the plugin")

local needs_config = Resolve.plan(context("java", { availability = java_ready }))
eq(needs_config.categories.lint.action, "none", "checkstyle needs config")

local has_config = Resolve.plan(context("java", {
  availability = java_ready,
  files = { ["checkstyle.xml"] = "/proj/checkstyle.xml" },
}))
eq(has_config.categories.lint.owner, "checkstyle", "checkstyle selected with config")

-- LSP coverage only counts when the LSP is already on ----------------------

local rust_availability = {
  rust_analyzer = { lsp = avail() },
  clippy = { lint = avail() },
  rustfmt = { format = avail() },
}
local rust_active = existing_with(function(existing)
  existing.lsp.active = { rust_analyzer = true }
  existing.lsp.sources = { rust_analyzer = { "active" } }
end)
local rust_plan = Resolve.plan(context("rust", { availability = rust_availability, existing = rust_active }))
eq(rust_plan.categories.lsp.owner, "rust_analyzer", "rust-analyzer owns the rust LSP")
eq(rust_plan.categories.lint.action, "keep", "rust lint stays with the active LSP")
eq(rust_plan.categories.lint.owner, "rust_analyzer", "rust lint owner is the LSP")
eq(rust_plan.categories.lint.mechanism, "lsp", "rust lint mechanism is lsp")

-- Required project root gates cargo-bound tools -----------------------------

local clippy_tool = Registry.tool("clippy")
eq(
  Score.root_evidence(clippy_tool, context("rust")),
  "needs root Cargo.toml",
  "a missing required root is reported"
)
eq(Score.root_evidence(clippy_tool, context("rust", { markers = { "Cargo.toml" } })), nil, "a root marker satisfies")
eq(
  Score.root_evidence(clippy_tool, context("rust", { files = { ["Cargo.toml"] = "/proj/Cargo.toml" } })),
  nil,
  "a project file satisfies"
)
eq(Score.root_evidence(Registry.tool("rust_analyzer"), context("rust")), nil, "tools without requires_root pass")

local cargo_plan = Resolve.plan(context("rust", {
  availability = rust_availability,
  markers = { "Cargo.toml" },
}))
eq(cargo_plan.categories.lint.action, "select", "a cargo project selects clippy for rust lint")
eq(cargo_plan.categories.lint.owner, "clippy", "clippy owns rust lint in a cargo project")

local projectless = Resolve.plan(context("rust", { availability = rust_availability }))
eq(projectless.categories.lint.action, "none", "a projectless rust buffer selects no linter")
local projectless_clippy = provider_by_id(projectless.categories.lint, "clippy")
if projectless_clippy == nil then
  error("clippy provider is missing from the projectless rust plan")
end
eq(projectless_clippy.eligible, false, "clippy is ineligible without a cargo project")
eq(
  table.concat(projectless_clippy.reasons, ", "):find("needs root Cargo%.toml") ~= nil,
  true,
  "the missing root is explained"
)
eq(projectless.categories.format.owner, "rustfmt", "rustfmt still formats projectless buffers")

local c_availability = {
  clangd = { lsp = avail() },
  clangtidy = { lint = avail() },
  clang_format = { format = avail() },
}
local c_plan = Resolve.plan(context("c", { availability = c_availability }))
eq(c_plan.categories.lsp.owner, "clangd", "clangd owns the C LSP")
eq(c_plan.categories.lint.owner, "clangtidy", "clang-tidy is chosen when clangd is not active")

-- TypeScript alternatives ----------------------------------------------------

local ts_availability = {
  ts_ls = { lsp = avail() },
  vtsls = { lsp = avail() },
  eslint = { lsp = avail(), lint = avail() },
  prettier = { format = avail() },
  biome = { format = avail() },
}

local both_enabled = existing_with(function(existing)
  existing.lsp.enabled = { ts_ls = true, vtsls = true }
  existing.lsp.sources = { ts_ls = { "runtime" }, vtsls = { "lazyvim" } }
end)
local ts_plan = Resolve.plan(context("typescript", { availability = ts_availability, existing = both_enabled }))
eq(ts_plan.categories.lsp.action, "keep", "enabled TypeScript LSP is kept")
eq(ts_plan.categories.lsp.owner, "ts_ls", "ts_ls wins the tie by registry order")

local vtsls_active = existing_with(function(existing)
  existing.lsp.active = { vtsls = true }
  existing.lsp.sources = { vtsls = { "active" } }
end)
local vtsls_plan = Resolve.plan(context("typescript", { availability = ts_availability, existing = vtsls_active }))
eq(vtsls_plan.categories.lsp.owner, "vtsls", "an active vtsls is kept")

local eslint_config = Resolve.plan(context("typescript", {
  availability = ts_availability,
  files = { [".eslintrc"] = "/proj/.eslintrc" },
  packages = { eslint = true },
}))
eq(eslint_config.categories.lint.owner, "eslint", "eslint wins lint when configured")
eq(
  eslint_config.categories.lint.reason:find("preferred when configured") ~= nil,
  true,
  "eslint preference is explained"
)

local format_plan = Resolve.plan(context("typescript", { availability = ts_availability }))
eq(format_plan.categories.format.owner, "prettier", "prettier beats biome by priority")

-- An active formatting client owns format even without registry coverage.
local formatting_lsp = existing_with(function(existing)
  existing.format.lsp = true
end)
local lsp_format_plan =
  Resolve.plan(context("typescript", { availability = ts_availability, existing = formatting_lsp }))
eq(lsp_format_plan.categories.format.action, "keep", "active formatting client keeps format")
eq(lsp_format_plan.categories.format.mechanism, "lsp", "format owner mechanism is lsp")
eq(lsp_format_plan.categories.format.reason, "already provided by an active LSP", "format lsp reason")

-- Gating ---------------------------------------------------------------------

local lint_off = Resolve.plan(context("python", { availability = python_availability() }), {
  languages = { python = true },
  categories = { lsp = true, lint = false, format = true },
})
eq(lint_off.categories.lint.action, "none", "disabled category is not resolved")
eq(lint_off.categories.lint.reason, "category disabled", "disabled category reason")

local language_off = Resolve.plan(context("python", { enabled = false, availability = python_availability() }))
eq(language_off.analyzed, false, "disabled language is not analyzed")
eq(language_off.reason, "language-disabled", "disabled language reason")

local unsupported = context("python", {})
unsupported.supported = false
unsupported.language = nil
unsupported.reason = "unsupported-filetype"
local unsupported_plan = Resolve.plan(unsupported)
eq(unsupported_plan.analyzed, false, "unsupported buffer is not analyzed")
eq(unsupported_plan.reason, "unsupported-filetype", "unsupported reason is preserved")

print("mimic resolve spec: ok")
