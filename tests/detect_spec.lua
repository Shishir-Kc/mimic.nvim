local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Detect = require("mimic.detect")
local Project = require("mimic.detect.project")
local Existing = require("mimic.detect.existing")
local Availability = require("mimic.detect.availability")

Detect.clear()

-- Language mapping ----------------------------------------------------------

local language, filetype, reason = Detect.language(1, {
  filetype = function()
    return "python"
  end,
})
eq(language, "python", "python filetype maps to python")
eq(filetype, "python", "language reports the filetype")
eq(reason, nil, "supported language has no reason")

local unknown, unknown_ft, unknown_reason = Detect.language(1, {
  filetype = function()
    return "text"
  end,
})
eq(unknown, nil, "unsupported filetype has no language")
eq(unknown_ft, "text", "unsupported filetype is reported")
eq(unknown_reason, "unsupported-filetype", "unsupported filetype reason")

local empty, _, empty_reason = Detect.language(1, {
  filetype = function()
    return ""
  end,
})
eq(empty, nil, "empty filetype has no language")
eq(empty_reason, "no-filetype", "empty filetype reason")

eq(
  Detect.language(1, {
    filetype = function()
      return "javascriptreact"
    end,
  }),
  "javascript",
  "jsx maps to javascript"
)
eq(
  Detect.language(1, {
    filetype = function()
      return "typescriptreact"
    end,
  }),
  "typescript",
  "tsx maps to typescript"
)
eq(
  Detect.language(1, {
    filetype = function()
      return "cpp"
    end,
  }),
  "cpp",
  "cpp stays its own language"
)

-- Project evidence ----------------------------------------------------------

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/src", "p")
vim.fn.mkdir(tmp .. "/.git", "p")
vim.fn.writefile({ "[tool.ruff]" }, tmp .. "/pyproject.toml")
vim.fn.writefile({ "requests" }, tmp .. "/requirements.txt")
vim.fn.writefile({ '{"devDependencies":{"typescript":"^5","prettier":"^3"}}' }, tmp .. "/package.json")

local project = Project.analyze(tmp .. "/src/main.py", "python")
eq(project.root, tmp, "project root from marker")
eq(project.root_source, "pyproject.toml", "root source is the marker")
eq(project.git_root, tmp, "git root is recorded")
eq(project.markers[1], "pyproject.toml", "pyproject.toml marker found")
eq(vim.tbl_contains(project.markers, "requirements.txt"), true, "requirements.txt marker found")
eq(project.files["pyproject.toml"] ~= nil, true, "pyproject.toml config file found")
eq(project.files["requirements.txt"], nil, "requirements.txt is a marker, not a tool config file")
eq(project.signals.python_requirements, true, "requirements signal")
eq(project.signals.python_venv, false, "missing venv signal is false")
eq(project.packages.typescript, true, "package.json dependency recorded")
eq(project.packages.prettier, true, "package.json dev dependency recorded")

local git_only = vim.fn.tempname()
vim.fn.mkdir(git_only .. "/repo/src", "p")
vim.fn.mkdir(git_only .. "/repo/.git", "p")
vim.fn.writefile({ "" }, git_only .. "/repo/src/main.rs")
local rust_project = Project.analyze(git_only .. "/repo/src/main.rs", "rust")
eq(rust_project.root, git_only .. "/repo", "git fallback root")
eq(rust_project.root_source, ".git", "git fallback root source")

local unnamed = Project.analyze("/definitely/missing/file.py", "python")
eq(unnamed.root, nil, "missing file has no root")
eq(#unnamed.markers, 0, "missing file has no markers")

-- Existing configuration ----------------------------------------------------

local clients = {
  {
    id = 1,
    name = "basedpyright",
    config = { root_dir = "/proj" },
    supports_method = function(_, method)
      return method == "textDocument/formatting"
    end,
  },
}

local existing_env = {
  filetype = function()
    return "python"
  end,
  lsp_clients = function()
    return clients
  end,
  lsp_is_enabled = function(name)
    return name == "ruff"
  end,
  lsp_configs = function()
    return { basedpyright = {} }
  end,
  lazyvim_opts = function()
    return nil
  end,
  conform = function()
    return {
      formatters_by_ft = { python = { "ruff_fix", "ruff_format" } },
      get_formatter_info = function(name)
        return { name = name, available = name == "ruff_fix" }
      end,
    }
  end,
  lint = function()
    return {
      linters_by_ft = { python = { "ruff" } },
      linters = { ruff = { cmd = "ruff" } },
      _resolve_linter_by_ft = function()
        return { "ruff" }
      end,
    }
  end,
  executable = function(exe)
    return exe == "ruff"
  end,
}

local lsp = Existing.lsp(1, "python", existing_env)
eq(lsp.active.basedpyright, true, "active client detected")
eq(lsp.enabled.ruff, true, "runtime enabled server detected")
eq(lsp.configured.basedpyright, true, "declared config detected")
eq(lsp.roots.basedpyright, "/proj", "active client root captured")
eq(vim.tbl_contains(lsp.sources.basedpyright, "active"), true, "active source tag")

local format = Existing.format(1, "python", existing_env)
eq(format.configured.ruff_fix, true, "conform formatter detected")
eq(format.configured.ruff_format, true, "second conform formatter detected")
eq(format.available.ruff_fix, true, "available formatter reported")
eq(format.available.ruff_format, nil, "unavailable formatter reported as absent")
eq(format.lsp, true, "LSP formatting capability detected")

local lint = Existing.lint(1, "python", existing_env)
eq(lint.configured.ruff, true, "linter detected")
eq(lint.available.ruff, true, "available linter reported")

-- Entries mimic applied are ignored so the plan explains mimic's choice
-- instead of echoing its own effect.
local own_env = vim.tbl_extend("force", existing_env, {
  mimic_state = function()
    return {
      format_edits = function()
        return { { ft = "python", value = { "ruff_fix", "ruff_format" } } }
      end,
      lint_edits = function()
        return { { ft = "python", names = { "ruff" }, value = { "ruff" } } }
      end,
    }
  end,
})

local own_format = Existing.format(1, "python", own_env)
eq(own_format.configured.ruff_fix, nil, "mimic formatter entry is ignored")
eq(own_format.configured.ruff_format, nil, "all mimic formatter entries are ignored")

local own_lint = Existing.lint(1, "python", own_env)
eq(own_lint.configured.ruff, nil, "mimic linter entry is ignored")

local replaced_env = vim.tbl_extend("force", own_env, {
  conform = function()
    return { formatters_by_ft = { python = { "black" } } }
  end,
  lint = function()
    return {
      linters_by_ft = { python = { "flake8" } },
      linters = { flake8 = { cmd = "flake8" } },
    }
  end,
})

local replaced_format = Existing.format(1, "python", replaced_env)
eq(replaced_format.configured.black, true, "a replaced formatter entry is detected")

local replaced_lint = Existing.lint(1, "python", replaced_env)
eq(replaced_lint.configured.flake8, true, "a replaced linter entry is detected")

local own_clients_env = vim.tbl_extend("force", existing_env, {
  mimic_state = function()
    return {
      clients = function()
        return { { id = 1, name = "basedpyright" } }
      end,
    }
  end,
})

local own_lsp = Existing.lsp(1, "python", own_clients_env)
eq(own_lsp.active.basedpyright, nil, "mimic client is not an existing owner")

local lazyvim_env = {
  filetype = function()
    return "rust"
  end,
  lsp_clients = function()
    return {}
  end,
  lsp_is_enabled = function()
    return false
  end,
  lsp_configs = function()
    return {}
  end,
  lazyvim_opts = function()
    return { servers = { rust_analyzer = { enabled = false } } }
  end,
}

local lazyvim_lsp = Existing.lsp(1, "rust", lazyvim_env)
eq(lazyvim_lsp.disabled.rust_analyzer, true, "LazyVim disabled server recorded")
eq(vim.tbl_contains(lazyvim_lsp.sources.rust_analyzer, "lazyvim"), true, "lazyvim source tag")

local empty_existing = Existing.empty()
eq(type(empty_existing.lsp.active), "table", "empty existing has lsp table")
eq(empty_existing.format.lsp, false, "empty existing disables lsp formatting")
eq(type(empty_existing.completion), "table", "empty existing has a completion record")

-- Completion engine ---------------------------------------------------------

local no_engine_env = {
  loaded = function()
    return nil
  end,
  has_runtime_file = function()
    return false
  end,
}
local no_engine = Existing.completion(no_engine_env)
eq(no_engine.engine, nil, "no engine when none is loaded")
eq(no_engine.source, nil, "no engine source when none is present")

local cmp_env = {
  loaded = function(name)
    return name == "cmp" and { register_source = true } or nil
  end,
}
eq(Existing.completion(cmp_env).engine, "nvim-cmp", "nvim-cmp is detected when loaded")
eq(Existing.completion(cmp_env).source, "runtime", "engine source tag")

local blink_env = {
  loaded = function(name)
    return name == "blink.cmp" and { setup = true } or nil
  end,
}
eq(Existing.completion(blink_env).engine, "blink.cmp", "blink.cmp is detected when loaded")

-- An installed engine counts before it is loaded: it can load at any moment
-- during the session and the builtin fill-in must not fight it. Presence is
-- visible on the runtimepath and in lazy's plugin list.
local installed_cmp_env = {
  loaded = function()
    return nil
  end,
  has_runtime_file = function(name)
    return name == "lua/cmp.lua" or name == "lua/cmp/init.lua"
  end,
}
eq(Existing.completion(installed_cmp_env).engine, "nvim-cmp", "an installed nvim-cmp is detected")
eq(Existing.completion(installed_cmp_env).source, "installed", "the installed engine source tag")

local lazy_cmp_env = {
  loaded = function()
    return nil
  end,
  has_runtime_file = function()
    return false
  end,
  lazy_plugin = function(name)
    return name == "nvim-cmp"
  end,
}
eq(Existing.completion(lazy_cmp_env).engine, "nvim-cmp", "nvim-cmp is detected through lazy")
eq(Existing.completion(lazy_cmp_env).source, "installed", "the lazy-detected engine source tag")

local disabled_env = {
  loaded = function()
    return nil
  end,
  has_runtime_file = function()
    return false
  end,
  lazy_plugin = function()
    return false
  end,
}
eq(Existing.completion(disabled_env).engine, nil, "a disabled plugin spec is not an engine")

-- Availability --------------------------------------------------------------

local availability_env = {
  executable = function(exe)
    return exe == "cargo"
  end,
  is_file = function(path)
    return path == "/proj/node_modules/.bin/prettier"
  end,
  is_dir = function(path)
    return path == "/mason/packages/jdtls"
  end,
  join = function(...)
    return table.concat({ ... }, "/")
  end,
  mason_dir = function()
    return "/mason"
  end,
  has_runtime_file = function(paths)
    return paths[1] == "lua/jdtls/init.lua"
  end,
}

local js = Availability.analyze("javascript", "/proj", availability_env)
eq(js.prettier.format.available, true, "project local prettier is available")
eq(js.prettier.format.source, "project", "project local source tag")
eq(js.eslint.lint.available, false, "eslint lint unavailable without project binary")
eq(js.eslint.lint.provided_by, "project", "eslint lint provided_by recorded")

local java = Availability.analyze("java", nil, availability_env)
eq(java.jdtls.lsp.available, true, "mason jdtls detected")
eq(java.jdtls.lsp.source, "mason", "mason source tag")
eq(java.jdtls.lsp.requires_plugin, "nvim-jdtls", "jdtls plugin requirement recorded")
eq(java.jdtls.lsp.plugin_available, true, "nvim-jdtls plugin availability recorded")

local rust = Availability.analyze("rust", nil, availability_env)
eq(rust.clippy.lint.available, true, "cargo on path makes clippy available")
eq(rust.clippy.lint.source, "path", "path source tag")
eq(rust.clippy.lint.provided_by, "rustup", "clippy provided_by recorded")
eq(rust.rustfmt.format.available, false, "rustfmt unavailable")

-- Full context --------------------------------------------------------------

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
vim.fn.writefile({ "[tool.ruff]" }, root .. "/pyproject.toml")

local bufnr = vim.fn.bufadd(root .. "/src/main.py")
vim.fn.bufload(bufnr)
vim.bo[bufnr].filetype = "python"

local context = Detect.context(bufnr, { config = { languages = { python = true } } })
eq(context.language, "python", "context language")
eq(context.supported, true, "context supported")
eq(context.enabled, true, "context enabled")
eq(context.root, root, "context root")
eq(context.root_source, "pyproject.toml", "context root source")
eq(type(context.existing.lsp.active), "table", "context existing lsp table")
eq(type(context.existing.completion), "table", "context existing completion record")
eq(type(context.availability.ruff), "table", "context availability table")
eq(context.availability.ruff.lint ~= nil, true, "context availability per category")

local disabled = Detect.context(bufnr, { config = { languages = { python = false } } })
eq(disabled.enabled, false, "context respects disabled language")

local nofile = vim.api.nvim_create_buf(true, false)
vim.bo[nofile].buftype = "nofile"
vim.bo[nofile].filetype = "python"
local nofile_context = Detect.context(nofile)
eq(nofile_context.supported, false, "nofile buffer not supported")
eq(nofile_context.reason, "buftype", "nofile buffer reason")

local unsupported = vim.api.nvim_create_buf(true, false)
vim.bo[unsupported].filetype = "text"
local unsupported_context = Detect.context(unsupported)
eq(unsupported_context.supported, false, "unsupported filetype not supported")
eq(unsupported_context.reason, "unsupported-filetype", "unsupported filetype reason")

eq(#vim.lsp.get_clients(), 0, "detection starts no LSP clients")

pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
pcall(vim.api.nvim_buf_delete, nofile, { force = true })
pcall(vim.api.nvim_buf_delete, unsupported, { force = true })
vim.fn.delete(tmp, "rf")
vim.fn.delete(git_only, "rf")
vim.fn.delete(root, "rf")

print("mimic detect spec: ok")
