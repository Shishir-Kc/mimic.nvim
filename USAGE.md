# How to use mimic.nvim

A practical, step-by-step guide. `mimic` detects the language and project
context of your current buffer and fills in the right LSP server, linter, and
formatter for that project. Your existing configuration always wins.
[USAGE.md](#) covers *using* the plugin; the [README](README.md) covers how it
works internally.

---

## 1. Requirements

Before installing, check you have:

| Requirement | Needed for |
| --- | --- |
| Neovim **0.11.3 or newer** | everything (`nvim --version` to check) |
| [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) | LSP server definitions |
| [conform.nvim](https://github.com/stevearc/conform.nvim) | formatting |
| [nvim-lint](https://github.com/mfussenegger/nvim-lint) | linting |
| [mason.nvim](https://github.com/mason-org/mason.nvim) | only `:Mimic install` (optional) |
| [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls) | only Java (optional) |

If you never run `:Mimic install`, you do not need Mason, and if you do not
edit Java, you do not need jdtls. Everything else is required.

---

## 2. Install

### lazy.nvim (recommended)

Add this to your plugin specs:

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
  opts = {}, -- zero-option setup
}
```

Notes:

- `opts = {}` runs `require("mimic").setup({})` with defaults. That is all
  most people need.
- The four dependencies are cloned by lazy.nvim if you do not already have
  them. Already installed versions are reused.
- `mimic` itself never downloads language tools. Tools are only installed when
  you explicitly run `:Mimic install` (see section 8).
- If you work with **Java**, also add:

  ```lua
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
  }
  ```

### LazyVim

Put the same table in a file such as `lua/plugins/mimic.lua` in your LazyVim
config. If you already have conform, nvim-lint, or mason through LazyVim
extras, lazy.nvim deduplicates them automatically.

### Manual (no plugin manager)

Clone the plugin and its dependencies, put all of them on your
`runtimepath`, and call setup once:

```lua
vim.cmd("runtime plugin/mimic.lua")
require("mimic").setup()
```

A plugin manager is strongly recommended because the LSP/format/lint
integrations need their runtime files present.

---

## 3. Zero-option quick start

This is the shortest path from install to working tools:

1. Restart Neovim.
2. Open a source file in a supported language, for example
   `nvim ~/myproject/src/main.py`.
3. Run `:Mimic status` to see what mimic detected and what it picked.
4. If the plan says a category has **no available tool**, run
   `:Mimic install` from that same buffer. It proposes the missing Mason
   packages, asks you to confirm, then installs them.
5. Run `:Mimic reload` (or restart Neovim) so the new plan is applied to open
   buffers.
6. Use the tools. Format with your normal keymap or
   `:lua require("conform").format()`. Linting runs automatically on
   `BufReadPost`, `BufWritePost`, and `InsertLeave` when mimic created the
   trigger (unless your config already had one).
7. Verify with `:checkhealth mimic`.

That is it. Mimic does not add keymaps; formatting is invoked through conform
and linting through nvim-lint, exactly like a hand-written config.

**Supported languages:** Python, Rust, C, C++, Java, JavaScript, TypeScript
(React filetypes count as JavaScript / TypeScript). A Lua, Go, or Markdown
buffer is simply ignored — no plan, no installs, no changes.

---

## 4. Commands

All behavior is behind one user command with four subcommands. Typing
`:Mimic` with no argument prints the usage line, and subcommand completion is
included (`:Mimic in<Tab>` completes to `install`). The commands also call
`setup()` for you if you have not done it manually.

| Command | What it does | When to use it |
| --- | --- | --- |
| `:Mimic status` | Shows setup state, session state, integration availability, registry and cache counts, the current buffer's detection result, its resolution plan, the install proposal, and everything mimic has applied (including overrides and what they replaced). | Your main "what is going on" command. Run it from the buffer you care about. |
| `:Mimic toggle` | Enables or disables mimic **for this session only**. Off reverts everything mimic applied and clears cached evidence; on applies to loaded buffers again. | Debugging a conflict, or testing whether a problem comes from mimic. |
| `:Mimic reload` | Reverts everything mimic applied, clears cached evidence and session state (including a toggle), and re-applies the original options. | After installing a tool, changing project files, or editing your config. |
| `:Mimic install` | Proposes and installs missing **Mason packages only** for the current buffer, subject to `install.mode`. Never installs plugins, never installs non-Mason tools. | When a plan category says `none` and the tool is Mason-installable. |

Important details about `:Mimic install`:

- Run it from a **real, supported buffer**. It builds its proposal for the
  current buffer only, so running it from an empty scratch buffer or an
  unsupported filetype does nothing.
- It fills only categories whose current action is `none`. Categories that
  already have an owner are left alone; optional alternatives and override
  targets are not installed.
- With the default `install.mode = "ask"`, it shows the proposal and waits for
  your confirmation before downloading. Without a UI to confirm in, it refuses
  rather than guessing.
- It reports non-Mason tools as **manual hints** instead of installing them,
  for example: clippy and rustfmt via rustup, clang-tidy via LLVM, ESLint via
  your project dependencies, and jdtls via nvim-jdtls.
- Installation is best effort: already-installed or busy packages are skipped
  and failures are reported. Mason remains the owner of installed packages,
  and mimic keeps no persistent install state of its own.

---

## 5. What mimic applies

On `FileType` (and when you run reload, toggle on, or a successful install),
mimic detects, resolves one owner per category, then applies:

| Category | What mimic writes | Notes |
| --- | --- | --- |
| `lsp` | Starts the LSP server it owns, once per buffer, via `vim.lsp.start` with an explicit project root. | Never uses `vim.lsp.enable`, so nothing is globally enabled. A running client with the same name and root is reused. If the server belongs to a provider plugin such as `rustaceanvim` or `nvim-jdtls`, mimic defers to that plugin instead of starting a second client. For Python, mimic sets `settings.python.pythonPath` from a project `.venv`, `venv`, or `virtualenv` — but only for clients mimic itself started. |
| `format` | Writes the selected formatter into `conform.formatters_by_ft` for that filetype — but only if the filetype has **no** entry yet. | If formatting is owned by an LSP (jdtls, clangd), it writes `{ lsp_format = "fallback" }` instead. |
| `lint` | Writes the selected linter into `lint.linters_by_ft` for that filetype — only if there is no entry yet. | If no nvim-lint trigger autocmd exists, mimic creates one for `BufReadPost`, `BufWritePost`, and `InsertLeave` so linting actually runs. When the linter's binding asks for it (clippy), mimic also sets `ignore_exitcode` on the loaded linter definition — but only if you have not set that field yourself — and records the write for revert. |

The golden rule: **keep beats select**. A category that is already owned
(a running or enabled LSP server, a configured formatter or linter — even one
mimic's registry does not know about) is left untouched. `:Mimic status` always
shows the resulting plan and which rule won, e.g.:

```
Plan:
  lsp:    select basedpyright (priority 100)
  lint:   select ruff (priority 100, manifest pyproject.toml)
  format: keep ruff (already configured (ruff))
```

Four possible actions per category:

- `keep` — something already owns it, do nothing.
- `select` — no owner, mimic picks the best eligible tool from its registry.
- `override` — opt-in replacement of an existing owner (see section 7).
- `none` — nothing eligible; a Mason install hint is shown when applicable.

Everything mimic changes is reversible: `:Mimic reload` and `:Mimic toggle` off
stop only the clients mimic created and restore only the conform / nvim-lint
entries mimic wrote.

---

## 6. Configuration cookbook

You only need to pass what differs from the defaults:

```lua
require("mimic").setup({
  enabled = true,                          -- master switch
  override = {                             -- opt-in, see section 7
    lsp = false,                           -- reserved, not implemented yet
    lint = false,
    format = false,
  },
  install = { mode = "ask" },              -- "ask" | "never" | "auto"
  languages = {                            -- every language is on by default
    python = true,
    rust = true,
    c = true,                              -- c and cpp are separate keys
    cpp = true,
    java = true,
    javascript = true,
    typescript = true,
  },
  categories = { lsp = true, lint = true, format = true },
  log_level = "warn",                      -- trace | debug | info | warn | error
})
```

Common recipes:

```lua
-- Turn mimic off by default, enable it ad hoc with :Mimic toggle
require("mimic").setup({ enabled = false })

-- Never download anything; show proposals only
require("mimic").setup({ install = { mode = "never" } })

-- Skip the confirmation prompt for explicit :Mimic install calls
require("mimic").setup({ install = { mode = "auto" } })

-- Ignore Java and C/C++; keep everything else
require("mimic").setup({
  languages = { java = false, c = false, cpp = false },
})

-- Lint and format only; define servers yourself. See section 7.
require("mimic").setup({ override = { lint = true, format = true } })
```

Validation behavior worth knowing:

- Unknown option keys produce **one** warning and are ignored
  (`mimic: unknown option foo ignored`).
- Invalid values keep their defaults and are reported the same way
  (`install.mode` must be `ask`, `never`, or `auto`).
- Calling `setup()` twice is a no-op unless `force` is used, which
  `:Mimic reload` does internally.

---

## 7. Override mode

By default mimic is a fill-in tool: if you already configured Black for
Python, mimic will not touch it. Override mode flips that for `lint` and
`format` (only): with it enabled, mimic replaces a configured linter or
formatter with the best-scoring tool from its own registry.

```lua
require("mimic").setup({
  override = { lint = true, format = true },
  -- shorthand that means the same thing: override = true
})
```

Rules override mode follows:

- If the existing owner is already the best tool, nothing changes.
- A **custom** entry (a formatter or linter name no registry tool owns) is
  never overwritten, and neither is a **mixed** entry (configured names from
  more than one tool). The plan explains which rule applied.
- The replaced value is recorded exactly — including multi-formatter lists and
  `{ lsp_format = "fallback" }` options — so `:Mimic reload` and
  `:Mimic toggle` off restore it.
- `override.lsp` is reserved and not implemented yet; setting it warns and is
  ignored. LSP ownership always stays fill-in.
- Applying the same override again without external changes is a no-op.

When you would use it: you copied a `conform` snippet with Black but your
newer projects standardize on Ruff, or LazyVim's default formatter does not
match your project. Enable override only for `format` if you want to keep
your existing linters:

```lua
require("mimic").setup({ override = { format = true } })
```

---

## 8. Language notes

- **Python**: registry candidates are basedpyright / pyright (LSP), ruff /
  flake8 / pylint / mypy (lint), ruff / black (format). Ruff is both a lint LSP
  and an external linter and formatter, and a dedicated config file such as
  `.flake8` or `ruff.toml` heavily favors the matching tool.
- **Rust**: rust-analyzer (LSP), clippy (lint), rustfmt (format). clippy and
  rustfmt are not Mason packages — install them with
  `rustup component add clippy rustfmt` and run `:Mimic reload` afterwards.
  Two further clippy details: it only runs inside a cargo project (a `Cargo.toml`
  at the detected project root), so a loose `main.rs` gets no linter at all
  instead of a failing `cargo` call; and inside a project mimic marks the
  clippy linter as tolerant of cargo's nonzero exit code, which nvim-lint
  reports as `cargo exited with code: 101` whenever the crate fails to build.
- **C / C++**: clangd (LSP), clang-tidy (lint, via LLVM) and clang-format
  (format). `c` and `cpp` are separate language keys and separate filetypes.
- **Java**: jdtls needs the optional `nvim-jdtls` plugin; without it mimic
  warns and defers. Checkstyle only becomes eligible when the project has a
  checkstyle config (e.g. `checkstyle.xml`).
- **JavaScript / TypeScript**: ts_ls / vtsls (alternatives, never both for the
  same project), eslint / biome (lint), prettier / biome / prettierd /
  eslint_d (format). The tool matching your config files and
  `package.json` dependencies wins.

---

## 9. Verify it is working

```vim
:Mimic status          " one-stop overview for the current buffer
:checkhealth mimic     " version, setup, registry, detection, plan, cache
:checkhealth vim.lsp   " is the LSP client attached?
:ConformInfo           " which formatters conform will run
:lua print(vim.inspect(require("lint").linters_by_ft))
```

In `:checkhealth mimic` a healthy setup looks like: version check passes,
`setup()` has run, `nvim-lspconfig`, `conform.nvim`, and `nvim-lint` are
available, the registry data is valid, detection works for the current buffer,
and detection reported a plan and proposal without errors.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Buffer: unsupported` or `no-filetype` in the plan | The current buffer is not a supported language (or has no filetype detected). | Open a real source file in one of the seven supported languages. |
| Plan says `none` and lists an install tool | The tool is simply not installed. | Mason tool: run `:Mimic install` from that buffer. Non-Mason (clippy, rustfmt, clang-tidy, ESLint…): install it yourself, then `:Mimic reload`. |
| `:Mimic install` proposes nothing | Every category already has an owner, or the current buffer is unsupported. | Check the plan in `:Mimic status`; the installer only fills empty categories. |
| Install downloads nothing | `install.mode = "never"`, Mason missing, or no UI available in `ask` mode while running headless. | Set `install = { mode = "auto" }` (still only on an explicit call), install Mason, or run interactively. |
| A formatter/linter I configured is untouched | Fill-in behavior. | That is correct. Opt into `override` for `format` / `lint` (see section 7). |
| Formatting does nothing | No keymap is bound to conform. | Use your existing keymap, e.g. `<leader>cf` on LazyVim, or `:lua require("conform").format()`. |
| Linter does not run on save | Your config already defines its own nvim-lint trigger, so mimic did not create one. | Make sure your own autocmd calls `require("lint").try_lint()`. |
| Rust buffer: plan says lint `none` with "requires Cargo.toml" | No cargo project at the detected root (e.g. a loose .rs file). `cargo clippy` cannot run without a manifest. | Open the buffer inside a cargo project, or configure a different linter yourself. |
| nvim-lint warns `cargo exited with code: 101` inside a project | Your own config owns the clippy linter, so mimic did not patch it (it never overrides user settings). | Set `require("lint").linters.clippy.ignore_exitcode = true` yourself, or check whether the crate actually fails to build. |
| An LSP I enabled is not started by mimic | Intentional: mimic never overrides LSP ownership. | Disable your own enablement for that server if you want mimic to own it. |
| Java: no jdtls, plan can't select it | `nvim-jdtls` plugin missing, or jdtls not installed. | Add nvim-jdtls, install jdtls (Mason or manual), `:Mimic reload`. |
| Newly installed tool (outside Neovim) not detected | Availability is cached per session, invalidated by events. | Run `:Mimic reload`, or refocus Neovim / save a file. |
| `mimic: unknown option … ignored` | A setup key is not in the defaults (typo or custom extension). | Remove or rename it; mimic intentionally rejects unknown keys. |

When in doubt: run `:Mimic status` in the affected buffer, then
`:checkhealth mimic`. Both explain the current state and never start LSP
clients, change conform / nvim-lint config, or download anything.

---

## 11. Workflow: adding mimic to an existing LazyVim setup

1. Add the plugin spec (section 2). LazyVim already ships conform, nvim-lint,
   lspconfig, and mason — nothing extra to install.
2. Restart and open a project in each language you care about, running
   `:Mimic status` each time. Because your existing configuration composes
   categories first, expect mostly `keep` actions: mimic adds only where you
   have nothing.
3. If you want mimic to *choose* formatting or linting instead of what you
   currently have, enable `override` (section 7) — one category at a time is
   the safest way to review its choices.
4. After any change to your own config that overlaps mimic, run
   `:Mimic reload` to pick up the new state.

Nothing mimic does requires LazyVim specifically, but the plugin is aware of
LazyVim's configuration sources and tags them in the plan.

---

## 12. Uninstalling / disabling

For the rest of this session only:

```vim
:Mimic toggle
```

Turning it off reverts everything mimic applied (stops its LSP clients, removes
the formatters and linters it wrote, removes a lint trigger it created) and
clears its cached evidence.

Permanently: remove the plugin spec (and the `opts = {}` setup) from your
config, then restart Neovim. There is nothing else to clean up — mimic holds
no persistent state outside Neovim, and uninstalling Mason packages is done
through Mason (`:Mason`), not through mimic.

---

## 13. Development (working on the plugin itself)

From a clone of this repository:

```sh
# Run the full headless smoke test in a clean profile
NVIM_APPNAME=mimic-test nvim --headless \
  -u tests/minimal_init.lua \
  -l tests/smoke.lua

# Regenerate the help tags
nvim --headless -u NONE \
  --cmd 'set runtimepath+=.' \
  -c 'helptags doc' \
  -c q
```

The clean `NVIM_APPNAME=mimic-test` profile isolates runs from any
LazyVim-flavored user config. See the README's *Development checks* section
for the complete list of spec and integration suites.
