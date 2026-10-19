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
      },
    },
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
