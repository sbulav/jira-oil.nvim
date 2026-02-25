---@class jira-oil.Config
---@field cli table
---@field view table
local config = {
  cli = {
    cmd = "jira",
    timeout = 10000,
    issues = {
      columns = { "key", "assignee", "status", "summary", "labels" },
      team_jql = "",
      exclude_jql = "issuetype != Epic",
      status_jql = "status=Open",
    },
  },
  view = {
    columns = {
      { name = "key", width = 12 },
      { name = "status", width = 15 },
      { name = "assignee", width = 15 },
      { name = "summary" },
    },
    default_sort = "key",
  },
  keymaps = {
    open = "<CR>",
    create = "<C-c>",
    refresh = "<M-r>",
    close = "<C-q>",
    save = "<C-s>",
  },
  -- Use ENV by default or override
  defaults = {
    project = vim.env.JIRA_PROJECT or "",
    assignee = vim.env.JIRA_ASSIGNEE or "me",
    issue_type = "Task",
  },
}

local M = {}

M.options = config

function M.setup(opts)
  if opts then
    M.options = vim.tbl_deep_extend("force", M.options, opts)
  end
end

return M
