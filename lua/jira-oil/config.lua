---@class jira-oil.Config
---@field cli table
---@field view table
local default_config = {
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
  -- Keymaps in jira-oil list buffers. Can be any value that `vim.keymap.set` accepts OR a table of
  -- keymap options with a `callback` (e.g. { callback = function() ... end, desc = "", mode = "n" })
  -- Additionally, if it is a string that matches "actions.<name>", it will use the mapping at
  -- require("jira-oil.actions").<name>
  -- Set to `false` to remove a keymap
  keymaps = {
    ["g?"] = { "actions.show_help", mode = "n" },
    ["gR"] = { "actions.reset", mode = "n" },
    ["<CR>"] = "actions.select",
    ["<C-c>"] = { "actions.create", mode = "n" },
    ["<M-r>"] = { "actions.refresh", mode = "n" },
    ["<C-q>"] = { "actions.close", mode = "n" },
    ["<C-s>"] = { "actions.save", mode = "n" },
  },
  -- Keymaps in jira-oil issue scratch buffers
  keymaps_issue = {
    ["g?"] = { "actions.show_help", mode = "n" },
    ["gR"] = { "actions.reset", mode = "n" },
    ["<C-q>"] = { "actions.close", mode = "n" },
    ["<C-s>"] = { "actions.save", mode = "n" },
  },
  -- Set to false to disable all of the above keymaps
  use_default_keymaps = true,
  keymaps_help = {
    border = nil,
  },
  -- Use ENV by default or override
  defaults = {
    project = vim.env.JIRA_PROJECT or "",
    assignee = vim.env.JIRA_ASSIGNEE or "me",
    issue_type = "Task",
  },
}

local M = {}

M.options = default_config

function M.setup(opts)
  opts = opts or {}
  local new_conf = vim.tbl_deep_extend("keep", opts, default_config)

  if not new_conf.use_default_keymaps then
    new_conf.keymaps = opts.keymaps or {}
    new_conf.keymaps_issue = opts.keymaps_issue or {}
  else
    if opts.keymaps then
      for k, v in pairs(opts.keymaps) do
        new_conf.keymaps[k] = v
      end
    end
    if opts.keymaps_issue then
      for k, v in pairs(opts.keymaps_issue) do
        new_conf.keymaps_issue[k] = v
      end
    end
  end

  M.options = new_conf
end

return M
