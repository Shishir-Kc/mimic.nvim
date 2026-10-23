-- Phase 8 installer spec.
--
-- Run with:
--   NVIM_APPNAME=mimic-test nvim --headless -u tests/minimal_init.lua -l tests/install_spec.lua
--
-- The proposal and orchestration tests use injectable environments, so they
-- never load Mason, refresh a registry, or download a package.

local function eq(actual, expected, label)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Config = require("mimic.config")
local Existing = require("mimic.detect.existing")
local Install = require("mimic.install")
local Proposal = require("mimic.install.proposal")
local Registry = require("mimic.registry")
local Resolve = require("mimic.resolve")

local function config(opts)
  local resolved = Config.resolve(opts or {})
  return resolved
end

local function availability(language, present)
  local out = {}
  for _, category in ipairs(Registry.categories) do
    for _, candidate in ipairs(Registry.candidates(language, category)) do
      local id = candidate.tool.id
      out[id] = out[id] or {}
      out[id][category] = {
        available = false,
        executable = candidate.binding.executable,
      }
      if present and present[id] and present[id][category] then
        out[id][category].available = true
        out[id][category].source = "mason"
      end
    end
  end
  return out
end

local function context(language, opts)
  opts = opts or {}
  return {
    bufnr = 1,
    enabled = opts.enabled ~= false,
    existing = Existing.empty(),
    filetype = language,
    files = opts.files or {},
    language = language,
    markers = opts.markers or {},
    packages = opts.packages or {},
    root = "/project",
    root_source = "marker",
    signals = {},
    supported = opts.supported ~= false,
    availability = opts.availability or availability(language),
  }
end

local function proposal(language, opts)
  opts = opts or {}
  local ctx = context(language, opts)
  local cfg = config(opts.config)
  local plan = Resolve.plan(ctx, cfg)
  return Proposal.build(ctx, plan, cfg), ctx, plan, cfg
end

local function names(packages)
  local out = {}
  for _, package in ipairs(packages) do
    out[#out + 1] = package.name
  end
  return table.concat(out, ",")
end

local function manual_by_tool(manual)
  local out = {}
  for _, item in ipairs(manual) do
    out[item.tool] = item
  end
  return out
end

local function package_by_name(packages, name)
  for _, package in ipairs(packages) do
    if package.name == name then
      return package
    end
  end
  return nil
end

-- Proposal ------------------------------------------------------------------

local python, python_context, python_plan, python_config = proposal("python")
eq(names(python.packages), "basedpyright,ruff", "bare python proposes basedpyright and ruff")
eq(#python.manual, 0, "bare python has no manual hints")
eq(table.concat(package_by_name(python.packages, "ruff").categories, ","), "lint,format", "ruff covers lint and format")
eq(package.loaded["mason"], nil, "building a proposal does not load Mason")

local before = vim.deepcopy(python_context.availability)
Proposal.build(python_context, python_plan, python_config)
eq(vim.deep_equal(python_context.availability, before), true, "proposal does not mutate availability")

local with_ruff = proposal("python", {
  availability = availability("python", {
    ruff = { lsp = true, lint = true, format = true },
  }),
})
eq(names(with_ruff.packages), "basedpyright", "existing ruff leaves only the python LSP to install")

local complete_python = proposal("python", {
  availability = availability("python", {
    basedpyright = { lsp = true },
    ruff = { lsp = true, lint = true, format = true },
  }),
})
eq(#complete_python.packages, 0, "a complete plan proposes nothing")
eq(#complete_python.manual, 0, "a complete plan has no manual hints")

local rust = proposal("rust")
eq(names(rust.packages), "rust-analyzer", "rust proposes the Mason LSP")
local rust_manual = manual_by_tool(rust.manual)
eq(rust_manual.clippy.reason, "requires Cargo.toml", "projectless clippy reports the cargo requirement")
eq(rust_manual.rustfmt.reason, "provided by rustup", "rustfmt is a rustup hint")

local cargo_rust = proposal("rust", { markers = { "Cargo.toml" } })
eq(names(cargo_rust.packages), "rust-analyzer", "a cargo project still proposes the Mason LSP")
local cargo_manual = manual_by_tool(cargo_rust.manual)
eq(cargo_manual.clippy.reason, "provided by rustup", "clippy is a rustup hint inside a cargo project")

local c = proposal("c")
eq(names(c.packages), "clang-format,clangd", "c proposes clangd and clang-format")
eq(manual_by_tool(c.manual).clangtidy.reason, "provided by LLVM", "c reports the LLVM hint")

local cpp = proposal("cpp")
eq(names(cpp.packages), "clang-format,clangd,cpplint", "cpp proposes cpplint too")
eq(manual_by_tool(cpp.manual).clangtidy, nil, "cpp does not report clang-tidy when cpplint fills lint")

local java = proposal("java")
eq(names(java.packages), "google-java-format", "java proposes the formatter")
eq(manual_by_tool(java.manual).jdtls.reason, "requires nvim-jdtls", "java reports the plugin requirement")
eq(manual_by_tool(java.manual).checkstyle.reason, "requires project config", "java reports the config requirement")

local java_plugin_availability = availability("java")
java_plugin_availability.jdtls.lsp.plugin_available = true
local java_plugin = proposal("java", { availability = java_plugin_availability })
eq(package_by_name(java_plugin.packages, "jdtls") ~= nil, true, "java proposes jdtls when the plugin is present")

local java_config = proposal("java", { files = { ["checkstyle.xml"] = true } })
eq(package_by_name(java_config.packages, "checkstyle") ~= nil, true, "java proposes checkstyle when config is present")

local javascript = proposal("javascript")
eq(names(javascript.packages), "prettier,typescript-language-server", "javascript proposes the LSP and formatter")
eq(manual_by_tool(javascript.manual).eslint.reason, "provided by project dependencies", "javascript reports eslint")

local javascript_no_format = proposal("javascript", {
  config = { categories = { format = false } },
})
eq(names(javascript_no_format.packages), "typescript-language-server", "a disabled category is not installed")

local disabled = proposal("javascript", { supported = false })
eq(#disabled.packages, 0, "an unsupported buffer proposes nothing")
eq(#disabled.manual, 0, "an unsupported buffer has no manual hints")

-- Installer orchestration ---------------------------------------------------

local function fake_mason(opts)
  opts = opts or {}
  local fake = {
    has_calls = {},
    install_calls = {},
    install_results = opts.install_results or {},
    installed = opts.installed or {},
    is_installed_calls = {},
    refresh_calls = 0,
  }

  function fake.refresh(callback)
    fake.refresh_calls = fake.refresh_calls + 1
    callback(opts.refresh_success ~= false, opts.refresh_error)
  end

  function fake.has_package(name)
    fake.has_calls[#fake.has_calls + 1] = name
    if opts.missing and opts.missing[name] then
      return false, "missing package"
    end
    return true, nil
  end

  function fake.is_installed(name)
    fake.is_installed_calls[#fake.is_installed_calls + 1] = name
    return fake.installed[name] == true, nil
  end

  function fake.install(name, callback)
    fake.install_calls[#fake.install_calls + 1] = name
    if fake.install_results[name] == false then
      callback(false, "installation failed")
    else
      callback(true, {})
    end
    return true, nil
  end

  return fake
end

local function install_env(mason, overrides)
  local notifications = {}
  local env
  local base = {
    current_config = function()
      return config()
    end,
    detect = function()
      return context("python")
    end,
    has_ui = function()
      return true
    end,
    invalidate = function()
      env.invalidated = (env.invalidated or 0) + 1
    end,
    mason = mason,
    mason_available = function()
      return true
    end,
    notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end,
    on_complete = function(result)
      env.completed = result
    end,
    reapply = function()
      env.reapplied = (env.reapplied or 0) + 1
    end,
    resolve = function(ctx, cfg)
      return Resolve.plan(ctx, cfg)
    end,
    select = function(items, select_opts, on_choice)
      env.selected_items = items
      env.selected_prompt = select_opts.prompt
      on_choice("Cancel")
    end,
  }
  base.notifications = notifications
  env = vim.tbl_extend("force", base, overrides or {})
  return env
end

local function has_message(env, text)
  for _, item in ipairs(env.notifications) do
    if item.message:find(text, 1, true) then
      return true
    end
  end
  return false
end

Install.reset()
local never_mason = fake_mason()
local never_cfg = config({ install = { mode = "never" } })
local never_env = install_env(never_mason)
eq(Install.start(never_cfg, never_env), false, "never mode stops before downloading")
eq(never_mason.refresh_calls, 0, "never mode does not refresh Mason")
eq(has_message(never_env, "install.mode is never"), true, "never mode explains why nothing happened")
eq(Install._active, nil, "never mode clears the active flag")

Install.reset()
local cancel_mason = fake_mason()
local cancel_env = install_env(cancel_mason)
eq(Install.start(config(), cancel_env), false, "cancelling the prompt stops the install")
eq(cancel_mason.refresh_calls, 0, "cancelling does not refresh Mason")
eq(has_message(cancel_env, "install cancelled"), true, "cancelling is reported")
eq(Install._active, nil, "cancelling clears the active flag")

Install.reset()
local install_mason = fake_mason()
local install_env_ok = install_env(install_mason, {
  select = function(items, select_opts, on_choice)
    on_choice("Install")
  end,
})
eq(Install.start(config(), install_env_ok), true, "confirming starts the install")
eq(install_mason.refresh_calls, 1, "confirming refreshes Mason once")
eq(table.concat(install_mason.install_calls, ","), "basedpyright,ruff", "confirming installs both packages")
eq(#install_env_ok.completed.installed, 2, "both packages are reported installed")
eq(install_env_ok.reapplied, 1, "successful install reapplies the plan")
eq(install_env_ok.invalidated, 2, "successful install invalidates availability before and after")
eq(Install._active, nil, "successful install clears the active flag")

Install.reset()
local auto_mason = fake_mason()
local auto_select_called = false
local auto_env = install_env(auto_mason, {
  select = function()
    auto_select_called = true
  end,
})
eq(Install.start(config({ install = { mode = "auto" } }), auto_env), true, "auto mode starts without a prompt")
eq(auto_select_called, false, "auto mode does not prompt")
eq(#auto_env.completed.installed, 2, "auto mode installs the proposal")

Install.reset()
local no_ui_mason = fake_mason()
local no_ui_env = install_env(no_ui_mason, {
  has_ui = function()
    return false
  end,
})
eq(Install.start(config(), no_ui_env), false, "ask mode refuses to download without a UI")
eq(no_ui_mason.refresh_calls, 0, "no-UI refusal does not refresh Mason")
eq(has_message(no_ui_env, "no UI"), true, "no-UI refusal explains the problem")

Install.reset()
local no_mason_env = install_env(fake_mason(), {
  mason_available = function()
    return false
  end,
})
eq(Install.start(config(), no_mason_env), false, "missing Mason stops the install")
eq(has_message(no_mason_env, "Mason is not available"), true, "missing Mason is reported")

Install.reset()
local partial_mason = fake_mason({ install_results = { ruff = false } })
local partial_env = install_env(partial_mason, {
  select = function(items, select_opts, on_choice)
    on_choice("Install")
  end,
})
eq(Install.start(config(), partial_env), true, "partial install starts")
eq(#partial_env.completed.installed, 1, "partial install reports one success")
eq(#partial_env.completed.failed, 1, "partial install reports one failure")
eq(partial_env.completed.failed[1].name, "ruff", "partial install names the failed package")
eq(partial_env.reapplied, 1, "partial install reapplies after a success")

Install.reset()
local failed_mason = fake_mason({ install_results = { basedpyright = false, ruff = false } })
local failed_env = install_env(failed_mason, {
  select = function(items, select_opts, on_choice)
    on_choice("Install")
  end,
})
eq(Install.start(config(), failed_env), true, "failed install starts")
eq(#failed_env.completed.failed, 2, "failed install reports both failures")
eq(failed_env.reapplied, nil, "failed install does not reapply")

Install.reset()
local installed_mason = fake_mason({ installed = { basedpyright = true, ruff = true } })
local installed_env = install_env(installed_mason, {
  select = function(items, select_opts, on_choice)
    on_choice("Install")
  end,
})
eq(Install.start(config(), installed_env), true, "already-installed packages still complete")
eq(#installed_mason.install_calls, 0, "already-installed packages are not installed again")
eq(#installed_env.completed.skipped, 2, "already-installed packages are reported skipped")
eq(installed_env.reapplied, nil, "skipping every package does not reapply")

Install.reset()
local refresh_mason = fake_mason({ refresh_success = false, refresh_error = "offline" })
local refresh_env = install_env(refresh_mason, {
  select = function(items, select_opts, on_choice)
    on_choice("Install")
  end,
})
eq(Install.start(config(), refresh_env), true, "refresh failure still tries cached packages")
eq(has_message(refresh_env, "refresh failed"), true, "refresh failure is reported")
eq(#refresh_env.completed.installed, 2, "cached packages can still install")

Install.reset()
local rust_context = context("rust", {
  availability = availability("rust", {
    rust_analyzer = { lsp = true },
  }),
})
local manual_env = install_env(fake_mason(), {
  detect = function()
    return rust_context
  end,
})
eq(Install.start(config(), manual_env), false, "manual-only proposals do not download")
eq(manual_env.mason.refresh_calls, 0, "manual-only proposals do not load Mason")
eq(has_message(manual_env, "manual: Clippy"), true, "manual-only proposals show the hints")

Install.reset()
local complete_context = context("python", {
  availability = availability("python", {
    basedpyright = { lsp = true },
    ruff = { lsp = true, lint = true, format = true },
  }),
})
local complete_env = install_env(fake_mason(), {
  detect = function()
    return complete_context
  end,
})
eq(Install.start(config(), complete_env), false, "a complete plan installs nothing")
eq(has_message(complete_env, "nothing to install"), true, "a complete plan explains that nothing is missing")

Install.reset()
Install._active = true
local busy_env = install_env(fake_mason())
eq(Install.start(config(), busy_env), false, "a second install is refused while one is active")
eq(has_message(busy_env, "already running"), true, "the active install is reported")
Install.reset()

-- Status uses the pure proposal and must not initialize Mason.
local old_path = vim.env.PATH
vim.env.PATH = "/nonexistent"
local mimic = require("mimic")
local status_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(status_buf, vim.fn.tempname() .. ".py")
vim.api.nvim_set_current_buf(status_buf)
vim.bo[status_buf].filetype = "python"
mimic.setup({ install = { mode = "never" } })
local status = mimic.status()
vim.env.PATH = old_path
eq(status.install.mode, "never", "status reports the install mode")
eq(type(status.install_proposal), "table", "status includes an install proposal")
eq(names(status.install_proposal.packages), "basedpyright,ruff", "status lists installable Mason packages")
eq(package.loaded["mason"], nil, "status does not load Mason")

print("mimic install spec: ok")
