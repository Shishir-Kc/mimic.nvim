-- Minimal init for the clean NVIM_APPNAME=mimic-test profile.
--
-- This avoids LazyVim and language extras on purpose. It also disables normal
-- plugin loading so the smoke test proves that plugin/mimic.lua is sourced
-- explicitly, not by accident.

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then
  source = source:sub(2)
end

local root = vim.fn.fnamemodify(source, ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.packpath = {}
vim.opt.swapfile = false
vim.opt.loadplugins = false

vim.cmd("runtime plugin/mimic.lua")
