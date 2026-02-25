if vim.g.loaded_jira_oil then
  return
end
vim.g.loaded_jira_oil = true

-- Register the user command unconditionally so it is discoverable
-- even before setup() is called. setup() must still be called to
-- configure the plugin before the command is useful.
vim.api.nvim_create_user_command("JiraOil", function(args)
  local ok, mod = pcall(require, "jira-oil")
  if not ok then
    vim.notify("[jira-oil] Failed to load plugin: " .. tostring(mod), vim.log.levels.ERROR)
    return
  end
  local target = args.args
  if target == "" then
    target = "all"
  end
  mod.open(target)
end, {
  nargs = "?",
  complete = function()
    return { "all", "sprint", "backlog" }
  end,
  desc = "Open Jira Oil buffer",
})
