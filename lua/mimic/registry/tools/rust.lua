return {
  {
    id = "rust_analyzer",
    label = "rust-analyzer",
    languages = { "rust" },
    categories = {
      lsp = {
        server = "rust_analyzer",
        role = "language",
        executable = "rust-analyzer",
        mason = "rust-analyzer",
        covers = { lint = true },
        provider_plugins = { "rustaceanvim" },
      },
    },
    config_files = { "rust-project.json", "rust-toolchain.toml" },
    priority = { lsp = 100 },
  },
  {
    id = "clippy",
    label = "Clippy",
    languages = { "rust" },
    categories = {
      lint = {
        linter = "clippy",
        executable = "cargo",
        mason = false,
        provided_by = "rustup",
        -- cargo clippy exits nonzero whenever the crate fails to build (rustc
        -- errors, failed build scripts). That is a normal editing state, so
        -- nvim-lint must not warn about it. The apply stage writes this into
        -- the loaded linter definition unless the user already set the field.
        ignore_exitcode = true,
      },
    },
    -- clippy only works inside a cargo project: it discovers the manifest by
    -- walking up from its working directory. Without one the tool cannot run,
    -- so it stays ineligible and mimic applies nothing.
    requires_root = { "Cargo.toml" },
    config_files = { "clippy.toml", ".clippy.toml" },
    priority = { lint = 50 },
  },
  {
    id = "rustfmt",
    label = "rustfmt",
    languages = { "rust" },
    categories = {
      format = {
        formatters = { "rustfmt" },
        executable = "rustfmt",
        mason = false,
        provided_by = "rustup",
      },
    },
    config_files = { "rustfmt.toml", ".rustfmt.toml" },
    priority = { format = 100 },
  },
}
