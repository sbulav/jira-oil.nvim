-- Demo config for jira-oil.nvim recordings
-- Usage: nvim -u demo/demo.lua

-- Set up runtimepath to find the plugin
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Disable some built-in plugins for cleaner startup
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- Basic settings for demo
vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.signcolumn = "no"
vim.opt.foldcolumn = "0"
vim.opt.laststatus = 2
vim.opt.cmdheight = 1
vim.opt.showmode = false
vim.opt.mouse = ""

-- Use a nice colorscheme if available
pcall(vim.cmd.colorscheme, "tokyonight")
pcall(vim.cmd.colorscheme, "catppuccin")
pcall(vim.cmd.colorscheme, "gruvbox")

-- Configure jira-oil with mock CLI
require("jira-oil").setup({
  cli = {
    cmd = vim.fn.getcwd() .. "/demo/jira-demo",
    timeout = 5000,
    cache = {
      enabled = false,
    },
    issues = {
      columns = { "key", "assignee", "status", "summary", "labels" },
      team_jql = "",
      exclude_jql = "issuetype != Epic",
      status_jql = "",
    },
    epics = {
      args = { "issue", "list", "--type", "Epic" },
      columns = { "key", "summary", "status" },
      filters = { "-s~done", "-s~closed" },
      order_by = "created",
    },
  },

  view = {
    columns = {
      { name = "status", width = 13 },
      { name = "assignee", width = 12 },
      { name = "summary" },
    },
    key_width = 10,
    default_sort = "key",
    show_winbar = true,
    sections = {
      show_count = true,
      sprint_label = "Sprint",
      backlog_label = "Backlog",
    },
    status_icons = {
      ["Open"] = "○ ",
      ["To Do"] = "○ ",
      ["In Progress"] = "▶ ",
      ["In Review"] = "👁 ",
      ["Done"] = "✓ ",
      ["Closed"] = "✓ ",
      ["Blocked"] = "⊘ ",
      default = "● ",
    },
    type_icons = {
      Task = "📋 ",
      Story = "📖 ",
      Epic = "⚡ ",
      ["Sub-task"] = "📋 ",
      Bug = "🐛 ",
      Improvement = "🔧 ",
      Feature = "✨ ",
      default = "📄 ",
    },
  },

  keymaps = {
    ["g?"] = { "actions.show_help", mode = "n" },
    ["gR"] = { "actions.reset", mode = "n" },
    ["<CR>"] = "actions.select",
    ["<C-c>"] = { "actions.create", mode = "n" },
    ["gB"] = { "actions.open_in_browser", mode = "n" },
    ["<C-y>"] = { "actions.yank_issue_key", mode = { "n", "v" } },
    ["dd"] = { "actions.move_issue_to_other_section", mode = "n" },
    ["p"] = { "actions.paste_after", mode = "n" },
    ["P"] = { "actions.paste_before", mode = "n" },
    ["<M-r>"] = { "actions.refresh", mode = "n" },
    ["<C-q>"] = { "actions.close", mode = "n" },
    ["<C-s>"] = { "actions.save", mode = "n" },
  },

  keymaps_issue = {
    ["g?"] = { "actions.show_help", mode = { "n", "i" } },
    ["gR"] = { "actions.reset", mode = { "n", "i" } },
    ["<C-e>"] = { "actions.pick_epic", mode = { "n", "i" } },
    ["<C-o>"] = { "actions.pick_components", mode = { "n", "i" } },
    ["gB"] = { "actions.open_in_browser", mode = { "n", "i" } },
    ["<C-y>"] = { "actions.yank_issue_key", mode = { "n", "i" } },
    ["<C-q>"] = { "actions.close", mode = { "n", "i" } },
    ["<C-s>"] = { "actions.save", mode = { "n", "i" } },
  },

  use_default_keymaps = true,
  keymaps_help = {
    border = "rounded",
    show_title = true,
    show_footer = true,
    key_width = 18,
    separator = " │ ",
    max_width_ratio = 0.9,
    max_height_ratio = 0.8,
  },

  defaults = {
    project = "DEMO",
    assignee = "Demo User",
    issue_type = "Task",
    status = "Open",
  },

  epic_field = "",
  create = {
    available_components = {
      "Backend",
      "Frontend",
      "API",
      "Database",
    },
  },
})

-- Auto-open JiraOil on startup
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.defer_fn(function()
      require("jira-oil").open("all")
    end, 100)
  end,
})
