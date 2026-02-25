local config = require("jira-oil.config")
local scratch = require("jira-oil.scratch")
local parser = require("jira-oil.parser")
local mutator = require("jira-oil.mutator")

local M = {}

---@param buf number
function M.setup(buf)
  local km = config.options.keymaps

  vim.keymap.set("n", km.open, function()
    local line = vim.api.nvim_get_current_line()
    local parsed = parser.parse_line(line)
    if parsed and parsed.key and parsed.key ~= "" then
      vim.cmd("edit jira-oil://issue/" .. parsed.key)
    end
  end, { buffer = buf, desc = "Open Jira issue" })

  vim.keymap.set("n", km.create, function()
    vim.cmd("edit jira-oil://issue/new")
  end, { buffer = buf, desc = "Create new Jira issue" })

  vim.keymap.set("n", km.refresh, function()
    require("jira-oil.view").refresh(buf)
  end, { buffer = buf, desc = "Refresh Jira issues" })

  vim.keymap.set("n", km.save, function()
    require("jira-oil.mutator").save(buf)
  end, { buffer = buf, desc = "Save Jira issues" })

  vim.keymap.set("n", km.close, function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, { buffer = buf, desc = "Close Jira issues list" })
end

return M
