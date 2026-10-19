local ts_configs = { "tsconfig.json", "jsconfig.json", "package.json" }

local eslint_configs = {
  "eslint.config.js",
  "eslint.config.mjs",
  "eslint.config.cjs",
  "eslint.config.ts",
  ".eslintrc",
  ".eslintrc.js",
  ".eslintrc.cjs",
  ".eslintrc.json",
  ".eslintrc.yml",
  ".eslintrc.yaml",
  "package.json",
}

local biome_configs = {
  "biome.json",
  "biome.jsonc",
  ".biome.json",
  ".biome.jsonc",
}

local prettier_configs = {
  ".prettierrc",
  ".prettierrc.json",
  ".prettierrc.json5",
  ".prettierrc.js",
  ".prettierrc.cjs",
  ".prettierrc.mjs",
  ".prettierrc.ts",
  ".prettierrc.yml",
  ".prettierrc.yaml",
  ".prettierrc.toml",
  "prettier.config.js",
  "prettier.config.cjs",
  "prettier.config.mjs",
  "prettier.config.ts",
  "package.json",
}

return {
  {
    id = "ts_ls",
    label = "TypeScript Language Server",
    languages = { "javascript", "typescript" },
    categories = {
      lsp = {
        server = "ts_ls",
        role = "language",
        executable = "typescript-language-server",
        mason = "typescript-language-server",
      },
    },
    config_files = ts_configs,
    packages = { "typescript" },
    aliases = { "tsserver" },
    priority = { lsp = 100 },
  },
  {
    id = "vtsls",
    label = "vtsls",
    languages = { "javascript", "typescript" },
    categories = {
      lsp = {
        server = "vtsls",
        role = "language",
        executable = "vtsls",
        mason = "vtsls",
      },
    },
    config_files = ts_configs,
    packages = { "typescript" },
    priority = { lsp = 90 },
  },
  {
    id = "eslint",
    label = "ESLint",
    languages = { "javascript", "typescript" },
    categories = {
      lsp = {
        server = "eslint",
        role = "lint",
        executable = "vscode-eslint-language-server",
        mason = "eslint-lsp",
        covers = { lint = true, format = true },
      },
      lint = {
        linter = "eslint",
        executable = "eslint",
        mason = false,
        provided_by = "project",
      },
    },
    config_files = eslint_configs,
    packages = { "eslint" },
    preferred_when_configured = true,
    priority = { lsp = 80, lint = 100 },
  },
  {
    id = "biome",
    label = "Biome",
    languages = { "javascript", "typescript" },
    categories = {
      lsp = {
        server = "biome",
        role = "lint",
        executable = "biome",
        mason = "biome",
        covers = { lint = true, format = true },
      },
      format = {
        formatters = { "biome-check" },
        executable = "biome",
        mason = "biome",
      },
    },
    config_files = biome_configs,
    packages = { "@biomejs/biome" },
    preferred_when_configured = true,
    priority = { lsp = 70, format = 70 },
  },
  {
    id = "prettier",
    label = "Prettier",
    languages = { "javascript", "typescript" },
    categories = {
      format = {
        formatters = { "prettier" },
        executable = "prettier",
        mason = "prettier",
      },
    },
    config_files = prettier_configs,
    packages = { "prettier" },
    priority = { format = 100 },
  },
  {
    id = "prettierd",
    label = "prettierd",
    languages = { "javascript", "typescript" },
    categories = {
      format = {
        formatters = { "prettierd" },
        executable = "prettierd",
        mason = "prettierd",
      },
    },
    config_files = prettier_configs,
    packages = { "prettierd" },
    priority = { format = 60 },
  },
  {
    id = "eslint_d",
    label = "eslint_d",
    languages = { "javascript", "typescript" },
    categories = {
      format = {
        formatters = { "eslint_d" },
        executable = "eslint_d",
        mason = "eslint_d",
      },
    },
    config_files = eslint_configs,
    packages = { "eslint_d" },
    priority = { format = 40 },
  },
}
