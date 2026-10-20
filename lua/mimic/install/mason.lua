---@brief
--- Lazy Mason adapter for the installer.
---
--- Nothing here loads Mason until a function is called. The installer calls
--- these functions only after the user has confirmed a download, so setup and
--- status never initialize Mason as a side effect.

local M = {}

local function load_mason()
  local ok, mason = pcall(require, "mason")
  if not ok then
    return nil, tostring(mason)
  end
  return mason, nil
end

local function load_registry()
  local ok, registry = pcall(require, "mason-registry")
  if not ok then
    return nil, tostring(registry)
  end
  return registry, nil
end

---Check whether Mason can be loaded.
---@return boolean available
---@return string|nil error
function M.available()
  local mason, err = load_mason()
  if mason == nil then
    return false, err
  end
  return true, nil
end

---Initialize Mason once. A user-managed setup is left untouched.
---@return boolean ok
---@return string|nil error
function M.ensure_setup()
  local mason, err = load_mason()
  if mason == nil then
    return false, err
  end

  if mason.has_setup == true then
    return true, nil
  end
  if mason.has_setup == nil and vim.fn.exists(":MasonInstall") == 2 then
    return true, nil
  end

  local ok, setup_err = pcall(mason.setup)
  if not ok then
    return false, tostring(setup_err)
  end
  return true, nil
end

---Refresh Mason's registry when it is stale.
---@param callback fun(success: boolean, error: any)|nil
---@return boolean started
---@return string|nil error
function M.refresh(callback)
  local ok, err = M.ensure_setup()
  if not ok then
    if callback then
      callback(false, err)
    end
    return false, err
  end

  local registry, registry_err = load_registry()
  if registry == nil then
    if callback then
      callback(false, registry_err)
    end
    return false, registry_err
  end

  local called = false
  local function done(success, result)
    if called then
      return
    end
    called = true
    if callback then
      callback(success == true, result)
    end
  end

  local refreshed, refresh_err = pcall(registry.refresh, done)
  if not refreshed then
    done(false, tostring(refresh_err))
  end
  return true, nil
end

---@param name string
---@return boolean installed
---@return string|nil error
function M.is_installed(name)
  local registry, err = load_registry()
  if registry == nil then
    return false, err
  end

  local ok, installed = pcall(registry.is_installed, name)
  if not ok then
    return false, tostring(installed)
  end
  return installed == true, nil
end

---@param name string
---@return boolean found
---@return string|nil error
function M.has_package(name)
  local registry, err = load_registry()
  if registry == nil then
    return false, err
  end

  local ok, found = pcall(registry.has_package, name)
  if not ok then
    return false, tostring(found)
  end
  return found == true, nil
end

---Install one Mason package.
---
---The callback receives the same result as Package:install. A package that is
---already installing or uninstalling is reported as a failure instead of
---letting Mason's assertion escape.
---
---@param name string
---@param callback fun(success: boolean, result: any)
---@return boolean started
---@return string|nil error
function M.install(name, callback)
  local registry, err = load_registry()
  if registry == nil then
    return false, err
  end

  local ok, package = pcall(registry.get_package, name)
  if not ok or type(package) ~= "table" then
    return false, tostring(package)
  end

  if package.is_installed and package:is_installed() then
    return false, "already installed"
  end
  if package.is_installing and package:is_installing() then
    return false, "already installing"
  end
  if package.is_uninstalling and package:is_uninstalling() then
    return false, "already uninstalling"
  end

  local installed, install_err = pcall(package.install, package, {}, callback)
  if not installed then
    return false, tostring(install_err)
  end
  return true, nil
end

return M
