local function get_module()
  return require("typecheck")
end

vim.api.nvim_create_user_command("TypeCheck", function()
  get_module().start()
end, {})

vim.api.nvim_create_user_command("TypeCheckStats", function()
  get_module().stats()
end, {})
