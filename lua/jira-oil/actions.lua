-- Lazy requires to avoid circular dependency: view -> actions -> mutator -> view
local config = require("jira-oil.config")

local M = {}

M.select = {
  desc = "Open Jira issue",
  callback = function()
    local view = require("jira-oil.view")
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
    local key = view.get_key_at_line(buf, row)
    if key and key ~= "" then
      vim.cmd.edit("jira-oil://issue/" .. key)
    end
  end,
}

M.create = {
  desc = "Create new Jira issue",
  callback = function()
    vim.cmd.edit("jira-oil://issue/new")
  end,
}

M.refresh = {
  desc = "Refresh Jira issues",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    require("jira-oil.view").refresh(buf)
  end,
}

M.save = {
  desc = "Save Jira changes",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    if vim.b[buf].jira_oil_kind == "issue" then
      require("jira-oil.scratch").save(buf)
    else
      require("jira-oil.mutator").save(buf)
    end
  end,
}

M.reset = {
  desc = "Reset unsaved changes",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    if vim.b[buf].jira_oil_kind == "issue" then
      require("jira-oil.scratch").reset(buf)
    else
      require("jira-oil.view").reset(buf)
    end
  end,
}

M.pick_epic = {
  desc = "Select epic",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    require("jira-oil.scratch").pick_epic(buf)
  end,
}

M.pick_components = {
  desc = "Select components",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    require("jira-oil.scratch").pick_components(buf)
  end,
}

M.close = {
  desc = "Close Jira buffer",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_delete(buf, { force = true })
  end,
}

M.show_help = {
  desc = "Show keymaps help",
  callback = function()
    local keymap_util = require("jira-oil.keymap_util")
    local buf = vim.api.nvim_get_current_buf()
    local kind = vim.b[buf].jira_oil_kind == "issue" and "Issue" or "List"
    local keymaps = config.options.keymaps
    if vim.b[buf].jira_oil_kind == "issue" then
      keymaps = config.options.keymaps_issue
    end
    keymap_util.show_help(keymaps, { context = kind })
  end,
}

---@param buf number
function M.setup(buf)
  local keymap_util = require("jira-oil.keymap_util")
  keymap_util.set_keymaps(config.options.keymaps, buf)
end

---@param buf number
function M.setup_issue(buf)
  local keymap_util = require("jira-oil.keymap_util")
  keymap_util.set_keymaps(config.options.keymaps_issue, buf)
end

return M
