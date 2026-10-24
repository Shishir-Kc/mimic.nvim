# mimic.nvim

Adaptive language tooling for Neovim and LazyVim. `mimic` is designed to detect
the language and project context of the current buffer, then choose and
configure the right LSP server, linter, and formatter. Existing configuration
always wins.

> **Status:** Phase 8 adds an opt-in Mason installer. For the current buffer,
> mimic detects the language, project root, project evidence, existing
> configuration, and tool availability, scores candidates into one explainable
> plan per category, and then applies its own choices: it starts the LSP servers
> it owns, fills conform and nvim-lint gaps, and with `override` enabled
> replaces a configured linter or formatter with the resolved best external
> tool. Existing configuration still wins unless override is enabled.
> `:Mimic install` can download missing Mason tools for categories with no
> owner. It never installs plugins, never installs non-Mason tools, and never
> downloads in the background.

A practical, step-by-step usage guide lives in [USAGE.md](USAGE.md).

## Requirements

- Neovim 0.11.3 or newer.
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) for LSP server definitions.
- [conform.nvim](https://github.com/stevearc/conform.nvim) for formatting.
- [nvim-lint](https://github.com/mfussenegger/nvim-lint) for linting.
- [mason.nvim](https://github.com/mason-org/mason.nvim) for `:Mimic install`.
  The plugin is optional if you install language tools yourself.

Java support additionally needs
[nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls). It is a soft
dependency and is not declared in the lazy.nvim spec below. `:Mimic status`
reports when it is missing.

## Installation

With lazy.nvim:

```lua
{
  "Shishir-Kc/mimic.nvim",
  event = "VeryLazy",
  dependencies = {
    "neovim/nvim-lspconfig",
    "stevearc/conform.nvim",
    "mfussenegger/nvim-lint",
    "mason-org/mason.nvim",
  },
  opts = {},
}
```

`lazy.nvim` clones the four declared plugin dependencies. `mimic` itself does
not download or install language tools during setup. Language tools such as
pyright, ruff, rust-analyzer, clangd, and jdtls are only installed when you run
`:Mimic install` explicitly. The installer uses Mason, fills only categories
that currently have no owner, and reports non-Mason tools as manual hints. It
never installs plugins.

Add `mfussenegger/nvim-jdtls` separately if you work with Java:

```lua
{
  "mfussenegger/nvim-jdtls",
  ft = "java",
}
```

## Zero-option setup

```lua
require("mimic").setup()
```

The defaults are:

```lua
{
  enabled = true,
  override = {
    lsp = false,
    lint = false,
    format = false,
  },
  install = { mode = "ask" },
  completion = {
    enabled = true,
    autotrigger = true,
  },
  languages = {
    python = true,
    rust = true,
    c = true,
    cpp = true,
    java = true,
    javascript = true,
    typescript = true,
  },
  categories = {
    lsp = true,
    lint = true,
    format = true,
  },
  log_level = "warn",
}
```

`c` and `cpp` are separate language keys. Unknown keys produce a single
warning and are ignored. Invalid values keep their defaults.

`override` accepts `false`, `true`, or a table. `true` enables `lint` and
`format` for the session, a table enables only the named categories, and `lsp`
is reserved and not implemented yet. Unknown override categories produce a
warning and are ignored.

`install.mode` controls what `:Mimic install` does:

- `ask` shows the proposed Mason packages and asks before downloading. If
  Neovim has no UI to confirm, it refuses and explains why.
- `never` reports the proposal and manual hints, but downloads nothing.
- `auto` skips the prompt for an explicit `:Mimic install` call.

No mode installs anything in the background. Setup, `FileType`, `reload`, and
`toggle` never download packages.

## Supported languages and tools

The registry lists candidate tools for each language. These are fallback
priorities, not forced choices. Existing configuration and project evidence
always win.

| Language | Language LSP | Lint | Format |
| --- | --- | --- | --- |
| Python | basedpyright, pyright | ruff, flake8, pylint, mypy | ruff, black |
| Rust | rust-analyzer | clippy, rust-analyzer coverage | rustfmt |
| C | clangd | clang-tidy, clangd coverage | clang-format |
| C++ | clangd | clang-tidy, cpplint, clangd coverage | clang-format |
| Java | jdtls | checkstyle with project config | jdtls, google-java-format |
| JavaScript | ts_ls, vtsls | eslint, biome LSP | prettier, biome, prettierd, eslint_d |
| TypeScript | ts_ls, vtsls | eslint, biome LSP | prettier, biome, prettierd, eslint_d |

Language LSPs are alternatives, so mimic will not start both `ts_ls` and
`vtsls` for the same project. Lint and format can be owned by an LSP when it
provides that capability, for example clangd with `--clang-tidy` or jdtls
formatting. Ruff is both a lint LSP and an external linter and formatter.

Clippy is cargo-bound: it only becomes eligible when the detected project root
has a `Cargo.toml`, so a loose `.rs` file outside a cargo project selects no
linter instead of registering a tool that could never run. Inside a cargo
project, mimic marks the clippy linter definition to tolerate cargo's expected
nonzero exit code (see Applying).

The registry is static. Loading it starts no LSP clients, changes no conform or
nvim-lint configuration, calls no Mason APIs, and downloads nothing.

## Detection

Detection is read only and runs on demand, for example from `:Mimic status` or
`:checkhealth mimic`. It never starts an LSP client, never changes conform or
nvim-lint configuration, never calls Mason, and never downloads anything.

For a buffer, detection reports:

- Language: the registry language for the buffer filetype. JavaScript React and
  TypeScript React filetypes map to `javascript` and `typescript`. C and C++
  stay separate.
- Project root: the nearest directory with a registry root marker, falling back
  to `.git`. The marker that matched is reported.
- Project evidence: root markers present, tool config files present, a few
  package manager signals (for example `poetry.lock`, `Cargo.lock`,
  `compile_commands.json`, `gradlew`, lockfiles), and dependency names from
  `package.json`.
- Existing configuration: active LSP clients, LSP servers enabled or declared
  with `vim.lsp`, LSP servers declared in LazyVim `opts`, formatters configured
  in conform, linters configured in nvim-lint, whether LSP formatting is
  available, and the completion engine (`nvim-cmp`, `blink.cmp`, or none),
  including whether it was seen loaded or merely installed. Each record is
  tagged with its source.
- Tool availability: for every registry candidate, whether its executable is
  found in a project local directory, on `PATH`, or in the Mason package
  directory. Plugin requirements such as `nvim-jdtls` are checked too.

Detection records sources but does not decide whether a source is user
configuration or a LazyVim extra. Scoring and the fill-in decision come later.
Detection also ignores the entries and clients that mimic itself applied, so the
plan explains what mimic would do rather than echoing its own effect.

## Resolution

Resolution is read only and pure. It turns a detection context into a plan with
one owner per category (`lsp`, `lint`, `format`). It starts no LSP client,
changes no conform or nvim-lint configuration, calls no Mason API, and performs
no downloads. The applier, described below, turns the plan into configuration.

Per category, the resolver:

1. Gathers providers. The `lsp` category only considers servers whose role is
   `language`. `lint` and `format` consider external tools plus LSP servers that
   cover the category, but an LSP coverage provider only counts when that server
   is already active or enabled. A newly selected server never silently absorbs
   a category it may not actually cover.
2. Keeps an existing owner. Active first, then enabled, then already configured,
   including a formatter or linter that is not in the registry. This is the
   fill-in rule: mimic does not override a running, enabled, or configured
   owner.
3. With override enabled for `lint` or `format`, and a replaceable existing
   owner, picks the best eligible tool instead. If it differs from the owner,
   the plan says `override` and records the previous owner. A custom or mixed
   entry is still kept, and the reason says so.
4. With no existing owner, scores the eligible providers and picks the best.
5. If nothing is eligible, chooses nothing and records an install hint when a
   preferred tool is simply missing.

Eligibility and scoring:

| Signal | Points |
| --- | --- |
| Base: registry `priority` for the category | 0 to 100 |
| Dedicated config file present | +60 |
| Shared manifest present (`package.json`, `pyproject.toml`, `setup.cfg`) | +10 |
| `package.json` dependency matches the tool | +25 |
| Executable found project-locally | +15 |
| `preferred_when_configured` and a dedicated config present | +40 |
| `deprecated` | -100 and ineligible |

A tool is ineligible when it is not installed, is deprecated, requires a plugin
that is missing (`nvim-jdtls`), requires project config that is absent
(`checkstyle`), or requires a project root that is absent (clippy needs a
`Cargo.toml` at the detected root). Ties break by registry order, which is
priority then tool id, so the result is deterministic.

A config file is dedicated when few tools list it and shared when many do, for
example `package.json` for every JavaScript tool. This is derived from the
registry, so it stays correct as tools are added.

Existing configuration is classified by authority. Active, declared, and
runtime-enabled servers count as user level. A server that only appears in
LazyVim `opts` counts as LazyVim level. The classification is reported in the
plan as the source of the previous owner, so an override decision is
explainable. Runtime enablement is indistinguishable from user configuration,
so both are reported as user level.

## Applying

The applier fills gaps by default. It acts on a resolved plan, and it touches a
category when the plan says `select` or `override`. When the plan says `keep`,
nothing is changed.

Each category is treated differently:

- `lsp`: mimic starts only the server it owns, once per buffer, with
  `vim.lsp.start` and an explicit `root_dir`. It never calls `vim.lsp.enable`,
  so it never globally enables a server. If a client with the same name and root
  is already running, it is reused. If the resolved server belongs to a provider
  plugin (`rustaceanvim`, `nvim-jdtls`), mimic defers to that plugin instead of
  starting a second client. Before starting, mimic checks that a table-shaped
  `cmd` points at a runnable executable.
- `format`: when the filetype has no `conform.formatters_by_ft` entry, mimic
  writes the selected formatter list. When the resolved owner is an LSP
  formatter, it writes `{ lsp_format = "fallback" }` instead. With override, it
  replaces the existing entry and records the previous value.
- `lint`: when the filetype has no `nvim-lint.linters_by_ft` entry, mimic writes
  the selected linter. If no `nvim-lint` trigger autocmd group exists, mimic
  creates one for `BufReadPost`, `BufWritePost`, and `InsertLeave`. With
  override, it replaces the existing entry and records the previous value.
  When the linter's binding asks for it, mimic also patches the loaded linter
  definition: clippy sets `ignore_exitcode`, because `cargo clippy` exits 101
  on every save while the crate fails to build, which nvim-lint would otherwise
  report as a warning. The patch only fills a field you have not set yourself,
  and the previous value is recorded so revert restores it.

conform and nvim-lint are loaded on demand, and only when mimic owns that
category. After requiring the plugin, mimic checks the filetype key again before
writing, so a setup hook that already filled the key still wins.

For Python, when mimic starts `basedpyright` or `pyright`, it sets
`settings.python.pythonPath` from a project `.venv`, `venv`, or `virtualenv`. It
does this only for clients it starts, never for servers the user manages.

Application is per buffer. `setup()` creates one `mimic` `FileType` autocmd and
then sweeps buffers that are already loaded, because `VeryLazy` fires after the
first `FileType`. `:Mimic reload` reverts everything mimic changed, clears
detection and resolution state, and applies again. `:Mimic toggle` off reverts;
toggle on sweeps loaded buffers. After a successful install, mimic reverts its
own ledger and sweeps again without resetting your session enabled state.
Reverting stops only clients mimic created and restores only the conform and
nvim-lint keys mimic wrote.

## Override mode

Override is opt-in and off by default. It applies to `lint` and `format` only.
conform and nvim-lint use replaceable invocation tables, so replacing and
reverting them is exact. LSP servers stay fill-in only, because
`vim.lsp.enable` is global while mimic decides per project, and a detached
client can reattach on the next `FileType`.

```lua
require("mimic").setup({
  override = { lint = true, format = true },
})
```

The short form `override = true` enables `lint` and `format`.

When override is enabled and a category already has an owner, mimic replaces
that owner with the best eligible tool from the registry:

- The existing owner is kept when it is already the best tool, when no external
  tool is eligible, or when the entry is custom or mixed. The `:Mimic status`
  plan says which rule applied.
- A custom entry is a configured formatter or linter name that no registry tool
  owns. It is never overwritten.
- A mixed entry configures names from more than one tool. It is treated as
  custom and kept.
- An external linter or formatter can be replaced by an LSP that already
  provides the category when that LSP scores higher. For `format`, mimic writes
  `{ lsp_format = "fallback" }`, the same as a normal LSP selection. For `lint`,
  nvim-lint cannot express LSP coverage, so the existing owner is kept and the
  plan says the target is an LSP. Override never starts or stops LSP servers.
- `override.lsp` is reserved and not implemented yet. Setting it warns and is
  ignored.

Replacing an entry records the exact previous value, including
`{ lsp_format = "fallback" }` options and multi-formatter lists, so
`:Mimic reload` and `:Mimic toggle` off restore it. Applying the same override
again without an external change is a no-op and keeps the first recorded
previous value.

Runtime enablement is indistinguishable from user configuration, so a tool that
LazyVim enabled at runtime is reported as a user-level owner.

## Completion

An LSP server only supplies completion items; a client engine must still
request and render them. mimic fills that gap, but only when no engine owns it:

- With `nvim-cmp` or `blink.cmp` loaded, mimic enables nothing and defers to
  the engine, so the two never fight over the same keystrokes. An engine that
  is installed but not yet loaded counts too, because it could load at any
  moment; mimic checks both the runtimepath and lazy.nvim's plugin list.
  `:Mimic status` and `:checkhealth mimic` report the detected engine and
  whether it was seen loaded or installed.
- Without an engine, mimic enables Neovim's builtin completion when the servers
  it starts attach to a buffer: `vim.lsp.completion.enable(true, client.id,
  bufnr, { autotrigger = true })`. The enablement happens on `LspAttach`,
  after the server has initialized, because that is when its capabilities are
  known. Typing a trigger character such as `.` or `:` opens the popup.
- `completion = { enabled = false }` turns the fill-in off completely, and
  `completion = { autotrigger = false }` keeps the popup manual.
- Manual `<C-x><C-o>` triggering needs `omnifunc` pointed at LSP completion;
  mimic does not set buffer options for you.
- Every enablement is recorded in the ledger and reverted by `:Mimic reload`
  and `:Mimic toggle`.

Suggestions also need something to suggest. rust-analyzer, for example, only
offers auto-import entries such as `rand::random` for members of crates that
are dependencies in `Cargo.toml`. Run `cargo add rand` first, then give the
server a moment to index the workspace after it picks up the manifest.

## Caching

Detection caches only filesystem evidence:

- Project evidence per language and root: root markers, config files, package
  manager signals, and `package.json` dependencies.
- Tool availability per language and root: project-local binaries, `PATH`,
  Mason packages, and required plugin availability.

Existing configuration is never cached. Active LSP clients, conform entries,
nvim-lint entries, and the applier ledger are read fresh on every detection, so
user edits and mimic's own writes are always visible. Resolved plans are also
not cached, so `:Mimic status` always explains the current state.

The cache lives for the current Neovim session and is bounded to 256 entries
per layer. It is invalidated on these events:

| Event | Cached layer |
| --- | --- |
| `BufWritePost`, `FileChangedShellPost` | Project evidence |
| `FocusGained`, `VimResume`, `DirChanged` | Project evidence and availability |
| `User LazyLoad`, `User LazyDone` | Availability |
| `:Mimic reload`, `:Mimic toggle` | Everything, including statistics |

There are no OS-level filesystem watchers. An external project change made
while Neovim is focused is picked up on the next save, focus change, directory
change, or `:Mimic reload`. A tool installed outside Neovim is picked up when
focus returns or after `:Mimic reload`. A successful `:Mimic install`
invalidates availability and reapplies immediately. Cache invalidation alone
refreshes evidence only. Applying still happens on `FileType`, on `setup()` for
loaded buffers, on `reload` or `toggle`, and after an install, so a changed
project plan is not rewritten while you edit. Run `:Mimic reload` to apply a
changed plan to open buffers.

`:Mimic status` reports hit, miss, and entry counts. `:checkhealth mimic`
reports per-layer statistics and the invalidation events above.

## Installer

`:Mimic install` is the only command that can download language tools. It
builds a proposal for the current buffer only:

- It uses the same detection, availability, and resolution as `:Mimic status`.
- It leaves every category that already has an owner alone. Override targets
  and optional alternatives are not installed.
- It simulates Mason availability, resolves again, and proposes only Mason
  packages that would fill categories whose current action is `none`.
- It deduplicates packages that cover more than one category. For example,
  Ruff owns both Python lint and format.
- It reports non-Mason tools as manual hints, including Clippy and rustfmt via
  rustup, clang-tidy via LLVM, ESLint via project dependencies, jdtls via
  nvim-jdtls, and checkstyle via project config. Clippy reports "requires
  Cargo.toml" when the buffer has no cargo project, and "provided by rustup"
  inside one.

The proposal is built without loading Mason. `status` and `health` also show
the proposal without initializing Mason, refreshing a registry, or downloading
anything. Only after `ask` is confirmed, or when `install.mode = "auto"` is set
for an explicit request, does mimic initialize Mason, refresh its registry, and
install the proposed packages.

Installation is best effort. Packages that are already installed or busy are
skipped, failures are reported, and the Mason registry refresh error is shown
without blocking cached packages. After at least one successful install, mimic
invalidates cached availability, reverts its own formatter, linter, and
completion ledger,
and sweeps loaded buffers again. Reverting first is required so a newly
installed formatter can replace an older formatter that mimic filled earlier.
Mimic-owned LSP clients may restart during that reapply. Your own configuration
and session enabled state are preserved.

The installer does not install plugins, non-Mason tools, all languages at once,
updates, uninstalls, or version pins. It has no language argument and keeps no
persistent install state. Mason remains the owner of installed packages.

## Commands

| Command | Behavior |
| --- | --- |
| `:Mimic status` | Show setup state, session state (including the enabled override categories and install mode), integration availability, registry counts, cache counts, the current buffer's detection result (including the detected completion engine), its resolution plan, installable Mason packages and manual hints, and what mimic has applied, including any override, the owner it replaced, and builtin completion mimic enabled. |
| `:Mimic toggle` | Enable or disable mimic for this session only. Turning off reverts everything mimic applied and clears cached evidence; turning on clears cached evidence and applies to loaded buffers again. |
| `:Mimic reload` | Revert what mimic applied, clear cached evidence and session state, and reapply the original options. |
| `:Mimic install` | Propose and install missing Mason packages for the current buffer, subject to `install.mode`. Never installs plugins or non-Mason tools. |

Completion for subcommands is included.

## Health

```vim
:checkhealth mimic
```

The check verifies the Neovim version, whether `setup()` has run, which
integration points are present, whether override is enabled, the install mode,
which completion engine is running (loaded or installed), whether the registry
data is valid, whether
detection works for the current buffer, the resulting plan and install
proposal, cache hit and miss counts, and how much the applier has changed,
including active overrides. It never loads Mason and never installs anything.

## Development checks

Headless load with the plugin file explicitly sourced:

```sh
nvim --headless -u NONE \
  --cmd 'set runtimepath+=.' \
  --cmd 'runtime plugin/mimic.lua' \
  -c 'lua require("mimic").setup()' \
  -c 'Mimic status' \
  -c q
```

Clean profile registry spec:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/registry_spec.lua
```

Registry integration check against installed plugin data. It skips when the
plugins are not on `runtimepath`:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lspconfig' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
  -l tests/registry_integration.lua
```

Clean profile cache spec:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/cache_spec.lua
```

Clean profile detection spec:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/detect_spec.lua
```

Detection integration check against installed plugins:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lspconfig' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/mason.nvim' \
  -l tests/detect_integration.lua
```

Clean profile resolution spec:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/resolve_spec.lua
```

Resolution integration check against installed plugins:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lspconfig' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/mason.nvim' \
  -l tests/resolve_integration.lua
```

Clean profile installer spec. It uses fake adapters, so it loads no Mason
module, refreshes no registry, and downloads nothing:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/install_spec.lua
```

Installer integration check against the real Mason registry. It is read only
and skips when Mason has no cached registry:

```sh
nvim --headless \
  -u tests/minimal_init.lua \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/mason.nvim' \
  -l tests/install_integration.lua
```

The check uses the default profile so it can see Mason's cached registry. It
never refreshes the registry and never installs a package.

Clean profile smoke test, isolated from the main LazyVim config:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/smoke.lua
```

Clean profile applier spec. It uses an injectable environment, so it starts no
real servers and touches no real plugin state:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/apply_spec.lua
```

Applier integration check against the real conform and nvim-lint tables. It
fills and reverts the tables and starts no LSP client:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
  -l tests/apply_integration.lua
```

Override integration check against the real conform and nvim-lint tables. It
replaces a pre-configured formatter and linter, then reverts them:

```sh
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/conform.nvim' \
  --cmd 'set runtimepath+=$HOME/.local/share/nvim/lazy/nvim-lint' \
  -l tests/override_integration.lua
```

Generate help tags:

```sh
nvim --headless -u NONE \
  --cmd 'set runtimepath+=.' \
  -c 'helptags doc' \
  -c q
```

The clean `NVIM_APPNAME=mimic-test` profile is the test bed for the applier and
installer, because the main config already covers many languages.

## What mimic does not do

- No LSP override. `override.lsp` is reserved and ignored, because global
  enablement and per-project decisions do not mix cleanly.
- No third-party completion engine. mimic defers to nvim-cmp or blink.cmp when
  one is installed or loaded, and otherwise enables Neovim's builtin LSP
  completion for the servers it starts, when they attach to a buffer. See
  Completion.
- No background installation. Only an explicit `:Mimic install` can download,
  and only after the configured confirmation rule.
- No plugin installation. The installer only proposes Mason packages and
  reports other tools as manual hints.
- No non-Mason package managers. Clippy, rustfmt, and clang-tidy need rustup or
  LLVM, ESLint needs project dependencies, and Java needs nvim-jdtls.
- No all-language install, language argument, update, uninstall, or version
  pinning. Mason remains the owner of installed packages.
- No installation state persisted by mimic.
- No project file parsing beyond existence checks and `package.json`
  dependency names.
- No executable introspection. Availability checks the filesystem only, it does
  not ask rustup, pip, or any other tool what it has installed.
- No OS-level filesystem watchers. Cached evidence is invalidated by Neovim
  events, `:Mimic reload`, and `:Mimic toggle`.
- No automatic re-apply when evidence changes. Application happens on
  `FileType`, on `setup()` for loaded buffers, on `reload` or `toggle`, and
  after a successful install.
- No persistent cache. Cached evidence lives only for the current session.
- No user-defined tool registry. Override only chooses among registry tools, and
  a custom owner is kept.
- No Bun, Deno, framework, or runtime detection.
- No LazyVim internals required.

## License

MIT. See [LICENSE](LICENSE).
