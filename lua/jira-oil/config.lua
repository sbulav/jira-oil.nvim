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
    epics = {
      args = { "issue", "list", "--type", "Epic" },
      columns = { "key", "summary", "status" },
      filters = { "-s~done", "-s~closed" },
      order_by = "created",
      prefill_search = "",
    },
    epic_issues = {
      args = { "issue", "list" },
      columns = { "type", "key", "assignee", "status", "summary", "labels" },
      filters = { "-s~done", "-s~closed" },
      order_by = "status",
      prefill_search = "",
    },
  },
  view = {
    -- Editable columns rendered as inline buffer text.  The issue key is
    -- always rendered as read-only inline virtual text and is NOT listed here.
    columns = {
      { name = "status", width = 15 },
      { name = "assignee", width = 15 },
      { name = "summary" },
    },
    -- Display width reserved for the virtual-text key column (characters)
    key_width = 12,
    default_sort = "key",
    column_highlights = {
      key = "JiraOilKey",
      status = "JiraOilStatus",
      assignee = "JiraOilAssignee",
      summary = "JiraOilSummary",
    },
    status_highlights = {
      ["Open"] = "JiraOilStatusOpen",
      ["To Do"] = "JiraOilStatusOpen",
      ["In Progress"] = "JiraOilStatusInProgress",
      ["In Review"] = "JiraOilStatusInReview",
      ["Done"] = "JiraOilStatusDone",
      ["Closed"] = "JiraOilStatusDone",
      ["Blocked"] = "JiraOilStatusBlocked",
    },
    -- Nerd Font icons prepended to the status column text (configurable)
    status_icons = {
      ["Open"]        = " ",
      ["To Do"]       = " ",
      ["In Progress"] = " ",
      ["In Review"]   = " ",
      ["Done"]        = " ",
      ["Closed"]      = " ",
      ["Blocked"]     = " ",
      default         = " ",
    },
    -- Nerd Font icons for issue types
    type_icons = {
      Task         = " ",
      Story        = " ",
      Epic         = " ",
      ["Sub-task"] = " ",
      Bug          = " ",
      Improvement  = " ",
      Feature      = " ",
      default      = " ",
    },
    -- Section header configuration for the "all" (sprint + backlog) view
    sections = {
      show_count    = true,
      sprint_label  = "Sprint",
      backlog_label = "Backlog",
    },
    separator_highlight = "JiraOilSeparator",
    -- Show project / filter context in the winbar
    show_winbar = true,
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
    ["g?"] = { "actions.show_help", mode = { "n", "i" } },
    ["gR"] = { "actions.reset", mode = { "n", "i" } },
    ["<C-e>"] = { "actions.pick_epic", mode = { "n", "i" } },
    ["<C-o>"] = { "actions.pick_components", mode = { "n", "i" } },
    ["<C-q>"] = { "actions.close", mode = { "n", "i" } },
    ["<C-s>"] = { "actions.save", mode = { "n", "i" } },
  },
  -- Set to false to disable all of the above keymaps
  use_default_keymaps = true,
  keymaps_help = {
    border = nil,
  },
  -- Use ENV by default or override
  defaults = {
    project = vim.env.JIRA_PROJECT or "",
    assignee = vim.env.JIRA_USER or vim.env.JIRA_ASSIGNEE or "",
    issue_type = "Task",
    status = "Open",
  },
  epic_field = "customfield_12311",
  epic_clear_value = "null",
  create = {
    available_components = {},
  },
}

local M = {}

M.options = default_config

function M.setup(opts)
  opts = opts or {}

  -- Merge keymaps separately since tbl_deep_extend cannot handle `false` values
  -- (used to disable individual default keymaps)
  local user_keymaps = opts.keymaps
  local user_keymaps_issue = opts.keymaps_issue
  opts.keymaps = nil
  opts.keymaps_issue = nil

  local new_conf = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts)

  if not new_conf.use_default_keymaps then
    new_conf.keymaps = user_keymaps or {}
    new_conf.keymaps_issue = user_keymaps_issue or {}
  else
    -- Start with defaults, then apply user overrides (including `false` to disable)
    new_conf.keymaps = vim.deepcopy(default_config.keymaps)
    new_conf.keymaps_issue = vim.deepcopy(default_config.keymaps_issue)
    if user_keymaps then
      for k, v in pairs(user_keymaps) do
        if v == false then
          new_conf.keymaps[k] = nil
        else
          new_conf.keymaps[k] = v
        end
      end
    end
    if user_keymaps_issue then
      for k, v in pairs(user_keymaps_issue) do
        if v == false then
          new_conf.keymaps_issue[k] = nil
        else
          new_conf.keymaps_issue[k] = v
        end
      end
    end
  end

  M.options = new_conf
end

return M
