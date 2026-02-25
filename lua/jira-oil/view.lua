local cli = require("jira-oil.cli")
local parser = require("jira-oil.parser")
local config = require("jira-oil.config")
local actions = require("jira-oil.actions")

local M = {}

M.cache = {}

---@param buf number
---@param uri string
function M.open(buf, uri)
  local target = uri:match("^jira%-oil://(.*)$")
  if not target or (target ~= "sprint" and target ~= "backlog") then
    vim.notify("Invalid URI: " .. uri, vim.log.levels.ERROR)
    return
  end

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "jira-oil"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false

  -- Disable undo while loading
  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading " .. target .. "..." })

  local fetcher = target == "sprint" and cli.get_sprint_issues or cli.get_backlog_issues

  fetcher(function(issues)
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local lines = {}
    local structured = {}

    for _, issue in ipairs(issues) do
      table.insert(lines, parser.format_line(issue))
      table.insert(structured, parser.parse_line(parser.format_line(issue)))
    end

    M.cache[buf] = {
      uri = uri,
      target = target,
      original = structured,
    }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].undolevels = old_undolevels

    actions.setup(buf)
  end)
end

function M.refresh(buf)
  local data = M.cache[buf]
  if data then
    M.open(buf, data.uri)
  end
end

return M
