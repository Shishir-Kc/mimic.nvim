---@brief
--- Mason installer for mimic.
---
--- The installer fills only categories that currently have no owner. It builds
--- a proposal without loading Mason, then initializes Mason and downloads only
--- after confirmation. It never installs plugins, non-Mason tools, or tools
--- that are already covered by an existing owner.

local Proposal = require("mimic.install.proposal")
local Mason = require("mimic.install.mason")

local M = {}

M._active = nil

local function has_runtime_file(paths)
  for _, path in ipairs(paths) do
    if #vim.api.nvim_get_runtime_file(path, false) > 0 then
      return true
    end
  end
  return false
end

local function default_notify(message, level)
  vim.notify("mimic: " .. message, level or vim.log.levels.INFO, { title = "mimic" })
end

local function env_defaults()
  return {
    current_config = function()
      return require("mimic").config
    end,
    detect = function(config)
      return require("mimic.detect").context(0, { config = config })
    end,
    has_ui = function()
      return #vim.api.nvim_list_uis() > 0
    end,
    invalidate = function()
      require("mimic.detect").invalidate("availability")
    end,
    mason = Mason,
    mason_available = function()
      return has_runtime_file({ "lua/mason/init.lua" })
    end,
    notify = default_notify,
    reapply = function(config)
      require("mimic.apply").reapply(config)
    end,
    resolve = function(context, config)
      return require("mimic.resolve").plan(context, config)
    end,
    select = function(items, opts, on_choice)
      vim.ui.select(items, opts, on_choice)
    end,
  }
end

local function resolve_env(env)
  return vim.tbl_extend("keep", env or {}, env_defaults())
end

local function package_names(packages)
  local names = {}
  for _, package in ipairs(packages) do
    names[#names + 1] = package.name
  end
  return names
end

local function failure_reason(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  if type(value) == "table" then
    for _, key in ipairs({ "message", "reason", "error" }) do
      local item = value[key]
      if type(item) == "string" and item ~= "" then
        return item
      end
    end
  end
  return "installation failed"
end

local function short_reason(value)
  local text = failure_reason(value):gsub("%s+", " ")
  if #text > 160 then
    text = text:sub(1, 157) .. "..."
  end
  return text
end

local function format_entries(entries)
  local parts = {}
  for _, entry in ipairs(entries) do
    if entry.reason and entry.reason ~= "" then
      parts[#parts + 1] = ("%s (%s)"):format(entry.name, entry.reason)
    else
      parts[#parts + 1] = entry.name
    end
  end
  return table.concat(parts, ", ")
end

local function call(fn, ...)
  local ok, first, second = pcall(fn, ...)
  if not ok then
    return false, nil, tostring(first)
  end
  return true, first, second
end

---Start an install run.
---
---Returns false when the run stopped before downloading. It returns true when
---the install run began, which may be asynchronous. Tests can inject
---`on_complete` to observe the final result.
---
---@param config table|nil Resolved config.
---@param env table|nil Injectable Neovim access and Mason adapter.
---@return boolean accepted
function M.start(config, env)
  env = resolve_env(env)
  config = config or env.current_config()
  if config == nil then
    env.notify("setup() has not run; call require('mimic').setup() first", vim.log.levels.WARN)
    return false
  end
  if M._active then
    env.notify("an install is already running", vim.log.levels.WARN)
    return false
  end

  M._active = true

  local function stop(message, level)
    M._active = nil
    if message then
      env.notify(message, level)
    end
    return false
  end

  pcall(env.invalidate)

  local detected, context, detect_err = call(env.detect, config)
  if not detected or type(context) ~= "table" then
    return stop("detection failed: " .. tostring(detect_err or "no context"), vim.log.levels.WARN)
  end
  if not context.supported or not context.language then
    return stop(
      ("no supported language in the current buffer (%s)"):format(context.reason or "unsupported"),
      vim.log.levels.WARN
    )
  end
  if context.enabled == false then
    return stop(("language '%s' is disabled in the configuration"):format(context.language), vim.log.levels.WARN)
  end

  local planned, plan, plan_err = call(env.resolve, context, config)
  if not planned or type(plan) ~= "table" or not plan.analyzed then
    return stop(
      "resolution failed for the current buffer: " .. tostring(plan_err or (plan and plan.reason) or "not applicable"),
      vim.log.levels.WARN
    )
  end

  local proposed, proposal, proposal_err = call(Proposal.build, context, plan, config)
  if not proposed or type(proposal) ~= "table" then
    return stop("install proposal failed: " .. tostring(proposal_err or "no proposal"), vim.log.levels.WARN)
  end

  local mode = proposal.mode or "ask"
  local names = package_names(proposal.packages)
  local has_packages = #proposal.packages > 0
  local has_manual = #proposal.manual > 0

  if not has_packages and not has_manual then
    return stop(("nothing to install for %s; no enabled category needs a tool"):format(context.language))
  end

  local lines = {
    ("install plan for %s (mode %s)"):format(context.language, mode),
  }
  for _, package in ipairs(proposal.packages) do
    lines[#lines + 1] = ("  mason: %s (%s)"):format(package.name, table.concat(package.categories, ", "))
  end
  for _, item in ipairs(proposal.manual) do
    lines[#lines + 1] = ("  manual: %s: %s"):format(item.label, item.reason)
  end
  env.notify(table.concat(lines, "\n"))

  if mode == "never" then
    return stop("install.mode is never; nothing was downloaded", vim.log.levels.WARN)
  end

  if has_packages and not env.mason_available() then
    return stop(
      "Mason is not available; nothing was downloaded. Install mason.nvim or install the tools manually.",
      vim.log.levels.WARN
    )
  end

  if not has_packages then
    return stop("no Mason packages to install; the manual steps are listed above")
  end

  local function proceed()
    env.notify(
      ("installing %d Mason package%s: %s"):format(
        #proposal.packages,
        #proposal.packages == 1 and "" or "s",
        table.concat(names, ", ")
      )
    )

    local refresh_done = false
    local function on_refresh(refreshed, refresh_error)
      if refresh_done then
        return
      end
      refresh_done = true
      if not refreshed then
        env.notify(
          ("Mason registry refresh failed (%s); trying the cached registry"):format(short_reason(refresh_error)),
          vim.log.levels.WARN
        )
      end

      local state = {
        failed = {},
        installed = {},
        pending = 0,
        skipped = {},
        starting = true,
      }
      local completed = {}

      local function finish()
        if state.starting or state.pending > 0 then
          return
        end

        M._active = nil

        local result = {
          failed = state.failed,
          installed = state.installed,
          skipped = state.skipped,
        }

        if #state.installed > 0 then
          local invalidated = pcall(env.invalidate)
          if not invalidated then
            result.invalidate_error = "availability cache could not be invalidated"
          end

          local reapplied, reapply_err = pcall(env.reapply, config)
          if reapplied then
            result.reapplied = true
          else
            result.reapply_error = tostring(reapply_err)
          end
        end

        local summary = {}
        if #state.installed > 0 then
          summary[#summary + 1] = "installed: " .. table.concat(state.installed, ", ")
        end
        if #state.skipped > 0 then
          summary[#summary + 1] = "skipped: " .. format_entries(state.skipped)
        end
        if #state.failed > 0 then
          summary[#summary + 1] = "failed: " .. format_entries(state.failed)
        end
        if result.reapplied then
          summary[#summary + 1] = "reapplied mimic with the new tools"
        elseif result.reapply_error then
          summary[#summary + 1] = "reapply failed: " .. result.reapply_error
        end
        if result.invalidate_error then
          summary[#summary + 1] = result.invalidate_error
        end
        if #state.failed > 0 then
          summary[#summary + 1] = "run :Mason for installation details"
        end
        if #summary == 0 then
          summary[1] = "nothing was installed"
        end

        local level = vim.log.levels.INFO
        if #state.failed > 0 or result.reapply_error ~= nil or result.invalidate_error ~= nil then
          level = vim.log.levels.WARN
        end
        env.notify(table.concat(summary, "\n"), level)
        if env.on_complete then
          pcall(env.on_complete, result)
        end
      end

      local function on_install(name)
        return function(success, value)
          if completed[name] then
            return
          end
          completed[name] = true
          state.pending = state.pending - 1
          if success then
            state.installed[#state.installed + 1] = name
          else
            state.failed[#state.failed + 1] = {
              name = name,
              reason = short_reason(value),
            }
          end
          finish()
        end
      end

      for _, package in ipairs(proposal.packages) do
        local found_ok, found, found_err = call(env.mason.has_package, package.name)
        if not found_ok or not found then
          state.failed[#state.failed + 1] = {
            name = package.name,
            reason = found_err or "not found in the Mason registry",
          }
        else
          local installed_ok, installed, installed_err = call(env.mason.is_installed, package.name)
          if not installed_ok then
            state.failed[#state.failed + 1] = {
              name = package.name,
              reason = installed_err or "could not check install state",
            }
          elseif installed then
            state.skipped[#state.skipped + 1] = {
              name = package.name,
              reason = "already installed",
            }
          else
            state.pending = state.pending + 1
            local install_ok, started, start_err = call(env.mason.install, package.name, on_install(package.name))
            if not install_ok then
              started = false
              start_err = start_err or "installation could not start"
            end
            if not started and not completed[package.name] then
              completed[package.name] = true
              state.pending = state.pending - 1
              local reason = short_reason(start_err or "installation could not start")
              if reason:find("already installed", 1, true) then
                state.skipped[#state.skipped + 1] = { name = package.name, reason = "already installed" }
              elseif reason:find("already installing", 1, true) then
                state.skipped[#state.skipped + 1] = { name = package.name, reason = "already installing" }
              elseif reason:find("already uninstalling", 1, true) then
                state.skipped[#state.skipped + 1] = { name = package.name, reason = "already uninstalling" }
              else
                state.failed[#state.failed + 1] = { name = package.name, reason = reason }
              end
            end
          end
        end
      end

      state.starting = false
      finish()
    end

    local refresh_ok, refresh_started, refresh_err = pcall(env.mason.refresh, on_refresh)
    if not refresh_ok then
      if not refresh_done then
        on_refresh(false, refresh_started)
      end
    elseif not refresh_started and not refresh_done then
      on_refresh(false, refresh_err)
    end

    return true
  end

  if mode == "auto" then
    return proceed()
  end

  if not env.has_ui() then
    return stop(
      "install.mode is ask but Neovim has no UI to confirm. Nothing was downloaded. Use install.mode = 'auto' or run interactively.",
      vim.log.levels.WARN
    )
  end

  local accepted = nil
  local selected, select_err = pcall(env.select, { "Install", "Cancel" }, {
    kind = "mimic_install",
    prompt = ("Install %d Mason package%s for %s?"):format(
      #proposal.packages,
      #proposal.packages == 1 and "" or "s",
      context.language
    ),
  }, function(choice)
    if choice ~= "Install" then
      accepted = false
      stop("install cancelled; nothing was downloaded.")
      return
    end
    accepted = proceed()
  end)
  if not selected and accepted == nil then
    return stop("install prompt failed: " .. tostring(select_err), vim.log.levels.WARN)
  end
  if accepted ~= nil then
    return accepted
  end
  return true
end

---Clear installer state. Intended for tests.
function M.reset()
  M._active = nil
end

return M
