vim.opt.runtimepath:append(vim.fn.getcwd())

local plenary_path = vim.env.PLENARY_PATH
if plenary_path and plenary_path ~= "" then
  vim.opt.runtimepath:append(plenary_path)
end
