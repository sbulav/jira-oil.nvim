local config = require("jira-oil.config")
local parser = require("jira-oil.parser")
local mutator = require("jira-oil.mutator")
local keymap_util = require("jira-oil.keymap_util")

local M = {}

M.select = {
  desc = "Open Jira issue",
  callback = function()
    local line = vim.api.nvim_get_current_line()
    local parsed = parser.parse_line(line)
    if parsed and parsed.key and parsed.key ~= "" then
      vim.cmd("edit jira-oil://issue/" .. parsed.key)
    end
  end,
}

M.create = {
  desc = "Create new Jira issue",
  callback = function()
    vim.cmd("edit jira-oil://issue/new")
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
      mutator.save(buf)
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
    local buf = vim.api.nvim_get_current_buf()
    local keymaps = config.options.keymaps
    if vim.b[buf].jira_oil_kind == "issue" then
      keymaps = config.options.keymaps_issue
    end
    keymap_util.show_help(keymaps)
  end,
}

---@param buf number
function M.setup(buf)
  keymap_util.set_keymaps(config.options.keymaps, buf)
end

---@param buf number
function M.setup_issue(buf)
  keymap_util.set_keymaps(config.options.keymaps_issue, buf)
end

return M
