if vim.g.loaded_mimic then
  return
end
vim.g.loaded_mimic = 1

vim.api.nvim_create_user_command("Mimic", function(opts)
  require("mimic.command").dispatch(opts.args)
end, {
  nargs = "?",
  desc = "mimic: adaptive language tooling",
  complete = function(arglead)
    return require("mimic.command").complete(arglead)
  end,
})
