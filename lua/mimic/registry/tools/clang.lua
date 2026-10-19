local clang_configs = { ".clangd", "compile_commands.json", "compile_flags.txt" }

return {
  {
    id = "clangd",
    label = "clangd",
    languages = { "c", "cpp" },
    categories = {
      lsp = {
        server = "clangd",
        role = "language",
        executable = "clangd",
        mason = "clangd",
        covers = { lint = true },
        requires_args = { "--clang-tidy" },
      },
    },
    config_files = clang_configs,
    priority = { lsp = 100 },
  },
  {
    id = "clangtidy",
    label = "clang-tidy",
    languages = { "c", "cpp" },
    categories = {
      lint = {
        linter = "clangtidy",
        executable = "clang-tidy",
        mason = false,
        provided_by = "llvm",
      },
    },
    config_files = { ".clang-tidy" },
    priority = { lint = 50 },
  },
  {
    id = "cpplint",
    label = "cpplint",
    languages = { "cpp" },
    categories = {
      lint = {
        linter = "cpplint",
        executable = "cpplint",
        mason = "cpplint",
      },
    },
    config_files = { "CPPLINT.cfg" },
    priority = { lint = 40 },
  },
  {
    id = "clang_format",
    label = "clang-format",
    languages = { "c", "cpp" },
    categories = {
      format = {
        formatters = { "clang-format" },
        executable = "clang-format",
        mason = "clang-format",
      },
    },
    config_files = { ".clang-format", "_clang-format" },
    priority = { format = 100 },
  },
}
