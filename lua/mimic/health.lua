---@brief
--- :checkhealth mimic

local M = {}

---Run the health checks.
function M.check()
  local health = vim.health
  health.start("mimic")

  local version = vim.version()
  local neovim = ("%d.%d.%d"):format(version.major, version.minor, version.patch)
  if vim.fn.has("nvim-0.11.3") == 1 then
    health.ok(("Neovim %s satisfies the >= 0.11.3 requirement"):format(neovim))
  else
    health.error(("Neovim %s is too old"):format(neovim), { "mimic requires Neovim 0.11.3 or newer." })
  end

  local mimic = require("mimic")
  if mimic._did_setup then
    health.ok("setup() has run")
  else
    health.warn("setup() has not run", {
      "Call require('mimic').setup() from your plugin spec.",
    })
  end

  local override = mimic.config and mimic.config.override
  local override_categories = {}
  if type(override) == "table" then
    for _, category in ipairs({ "lsp", "lint", "format" }) do
      if override[category] == true then
        override_categories[#override_categories + 1] = category
      end
    end
  end
  if #override_categories == 0 then
    health.ok("override: off")
  else
    health.ok(("override: %s"):format(table.concat(override_categories, ",")))
  end

  local install_mode = mimic.config and mimic.config.install and mimic.config.install.mode or "ask"
  health.ok(("install mode: %s"):format(install_mode))

  local loaded, Registry = pcall(require, "mimic.registry")
  if not loaded then
    health.error("registry failed to load", { tostring(Registry) })
  else
    local valid, errors = Registry.validate()
    if valid then
      local stats = Registry.stats()
      health.ok(
        ("registry valid: %d languages, %d tools, %d candidates"):format(stats.languages, stats.tools, stats.candidates)
      )
    else
      health.error("registry validation failed", errors)
    end
  end

  local detect_loaded, Detect = pcall(require, "mimic.detect")
  if not detect_loaded then
    health.error("detection module failed to load", { tostring(Detect) })
  else
    local ok, context = pcall(Detect.context, 0)
    if not ok then
      health.error("detection failed for the current buffer", { tostring(context) })
    elseif context and context.language then
      health.ok(("detected %s (root %s)"):format(context.language, context.root or "none"))

      local resolve_loaded, Resolve = pcall(require, "mimic.resolve")
      if not resolve_loaded then
        health.error("resolution module failed to load", { tostring(Resolve) })
      else
        local planned, plan = pcall(Resolve.plan, context, mimic.config)
        if not planned then
          health.error("resolution failed for the current buffer", { tostring(plan) })
        elseif plan.analyzed then
          local function describe(entry)
            if not entry or entry.action == "none" then
              return "none"
            end
            return entry.action .. " " .. tostring(entry.owner)
          end
          health.ok(
            ("plan: lsp=%s, lint=%s, format=%s"):format(
              describe(plan.categories.lsp),
              describe(plan.categories.lint),
              describe(plan.categories.format)
            )
          )

          local proposed, proposal = pcall(function()
            return require("mimic.install.proposal").build(context, plan, mimic.config)
          end)
          if not proposed then
            health.warn("install proposal failed", { tostring(proposal) })
          elseif type(proposal) ~= "table" then
            health.warn("install proposal returned no data")
          elseif #proposal.packages > 0 or #proposal.manual > 0 then
            local packages = {}
            for _, package in ipairs(proposal.packages) do
              packages[#packages + 1] = ("%s (%s)"):format(package.name, table.concat(package.categories, ","))
            end
            if #packages > 0 then
              health.info(("installable: %s"):format(table.concat(packages, ", ")))
            end
            for _, item in ipairs(proposal.manual) do
              health.info(("manual: %s: %s"):format(item.label, item.reason))
            end
          end
        else
          health.info(("resolution inactive (%s)"):format(plan.reason or "not applicable"))
        end
      end
    else
      health.info("no supported language in the current buffer")
    end
  end

  local cache_loaded, Cache = pcall(require, "mimic.cache")
  if not cache_loaded then
    health.error("cache module failed to load", { tostring(Cache) })
  else
    local stats = Cache.stats()
    health.ok(
      ("cache: %d hits, %d misses, %d entries, %d evictions"):format(
        stats.hits,
        stats.misses,
        stats.entries,
        stats.evictions
      )
    )

    local names = {}
    for name in pairs(stats.namespaces) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local item = stats.namespaces[name]
      health.info(
        ("cache %s: %d hits, %d misses, %d entries, %d evictions"):format(
          name,
          item.hits,
          item.misses,
          item.entries,
          item.evictions
        )
      )
    end

    health.info(
      "cache invalidates on BufWritePost, FileChangedShellPost, FocusGained, VimResume, DirChanged, and User LazyLoad/LazyDone"
    )
  end

  local apply_loaded, Apply = pcall(require, "mimic.apply")
  if not apply_loaded then
    health.error("applier module failed to load", { tostring(Apply) })
  else
    local ok, applied = pcall(Apply.state)
    if not ok then
      health.error("applier state failed", { tostring(applied) })
    else
      health.ok(
        ("applied: %d client(s), %d format entr%s, %d lint entr%s"):format(
          #applied.clients,
          #applied.format_edits,
          #applied.format_edits == 1 and "y" or "ies",
          #applied.lint_edits,
          #applied.lint_edits == 1 and "y" or "ies"
        )
      )

      local overrides = 0
      for _, edit in ipairs(applied.format_edits) do
        if edit.replaced then
          overrides = overrides + 1
        end
      end
      for _, edit in ipairs(applied.lint_edits) do
        if edit.replaced then
          overrides = overrides + 1
        end
      end
      if overrides > 0 then
        health.ok(("overrides applied: %d"):format(overrides))
      end

      local patches = {}
      for _, edit in ipairs(applied.def_edits or {}) do
        patches[#patches + 1] = ("%s.%s"):format(edit.name, edit.field)
      end
      for _, edit in ipairs(applied.lint_edits or {}) do
        local patch = edit.patched
        if patch and patch.status == "kept" then
          patches[#patches + 1] = ("%s.%s kept (%s)"):format(patch.name, patch.field, patch.reason)
        end
      end
      if #patches > 0 then
        health.ok(("patched linter definitions: %s"):format(table.concat(patches, ", ")))
      end
    end
  end

  for _, item in ipairs(mimic.integrations()) do
    if item.available then
      health.ok(("%s found"):format(item.name))
    elseif item.optional then
      health.info(("%s not found (optional)"):format(item.name), { item.hint })
    else
      health.warn(("%s not found"):format(item.name), { item.hint })
    end
  end

  health.info(
    "mimic does not download language tools during setup; Mason packages are downloaded only for an explicit :Mimic install."
  )
end

return M
