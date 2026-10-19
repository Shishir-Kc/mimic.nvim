local pyright_configs = { "pyrightconfig.json", "pyproject.toml" }
local ruff_configs = { "ruff.toml", ".ruff.toml", "pyproject.toml" }

return {
  {
    id = "basedpyright",
    label = "basedpyright",
    languages = { "python" },
    categories = {
      lsp = {
        server = "basedpyright",
        role = "language",
        executable = "basedpyright-langserver",
        mason = "basedpyright",
      },
    },
    config_files = pyright_configs,
    packages = { "basedpyright" },
    priority = { lsp = 100 },
  },
  {
    id = "pyright",
    label = "Pyright",
    languages = { "python" },
    categories = {
      lsp = {
        server = "pyright",
        role = "language",
        executable = "pyright-langserver",
        mason = "pyright",
      },
    },
    config_files = pyright_configs,
    packages = { "pyright" },
    priority = { lsp = 90 },
  },
  {
    id = "ruff",
    label = "Ruff",
    languages = { "python" },
    categories = {
      lsp = {
        server = "ruff",
        role = "lint",
        executable = "ruff",
        mason = "ruff",
        covers = { lint = true },
      },
      lint = {
        linter = "ruff",
        executable = "ruff",
        mason = "ruff",
      },
      format = {
        formatters = { "ruff_fix", "ruff_format" },
        executable = "ruff",
        mason = "ruff",
      },
    },
    config_files = ruff_configs,
    packages = { "ruff" },
    priority = { lsp = 50, lint = 100, format = 100 },
  },
  {
    id = "ruff_lsp",
    label = "ruff-lsp",
    languages = { "python" },
    categories = {
      lsp = {
        server = "ruff_lsp",
        role = "lint",
        executable = "ruff-lsp",
        mason = false,
        provided_by = "pip",
        covers = { lint = true },
      },
    },
    config_files = ruff_configs,
    deprecated = true,
    priority = { lsp = 10 },
  },
  {
    id = "flake8",
    label = "Flake8",
    languages = { "python" },
    categories = {
      lint = {
        linter = "flake8",
        executable = "flake8",
        mason = "flake8",
      },
    },
    config_files = { ".flake8", "setup.cfg", "tox.ini" },
    packages = { "flake8" },
    preferred_when_configured = true,
    priority = { lint = 50 },
  },
  {
    id = "pylint",
    label = "Pylint",
    languages = { "python" },
    categories = {
      lint = {
        linter = "pylint",
        executable = "pylint",
        mason = "pylint",
      },
    },
    config_files = { ".pylintrc", "pylintrc", "pyproject.toml" },
    packages = { "pylint" },
    preferred_when_configured = true,
    priority = { lint = 40 },
  },
  {
    id = "mypy",
    label = "mypy",
    languages = { "python" },
    categories = {
      lint = {
        linter = "mypy",
        executable = "mypy",
        mason = "mypy",
      },
    },
    config_files = { "mypy.ini", ".mypy.ini", "pyproject.toml", "setup.cfg" },
    packages = { "mypy" },
    preferred_when_configured = true,
    priority = { lint = 30 },
  },
  {
    id = "black",
    label = "Black",
    languages = { "python" },
    categories = {
      format = {
        formatters = { "black" },
        executable = "black",
        mason = "black",
      },
    },
    config_files = { "pyproject.toml" },
    packages = { "black" },
    priority = { format = 80 },
  },
}
