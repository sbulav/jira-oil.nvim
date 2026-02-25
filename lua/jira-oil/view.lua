local cli = require("jira-oil.cli")
local parser = require("jira-oil.parser")
local config = require("jira-oil.config")
local actions = require("jira-oil.actions")

local M = {}

M.cache = {}
M.separator = "----- backlog -----"

---@param buf number
---@param uri string
function M.open(buf, uri)
  local target = uri:match("^jira%-oil://(.*)$")
  if not target or (target ~= "sprint" and target ~= "backlog" and target ~= "all") then
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

  local function render_section(issues, section, lines, structured)
    for _, issue in ipairs(issues) do
      local line = parser.format_line(issue)
      table.insert(lines, line)
      local parsed = parser.parse_line(line)
      if parsed then
        parsed.section = section
        table.insert(structured, parsed)
      end
    end
  end

  local function finish(lines, structured)
    if not vim.api.nvim_buf_is_valid(buf) then return end

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
  end

  if target == "all" then
    cli.get_sprint_issues(function(sprint_issues)
      cli.get_backlog_issues(function(backlog_issues)
        local lines = {}
        local structured = {}

        render_section(sprint_issues, "sprint", lines, structured)
        table.insert(lines, M.separator)
        render_section(backlog_issues, "backlog", lines, structured)

        finish(lines, structured)
      end)
    end)
  else
    local fetcher = target == "sprint" and cli.get_sprint_issues or cli.get_backlog_issues
    fetcher(function(issues)
      local lines = {}
      local structured = {}
      render_section(issues, target, lines, structured)
      finish(lines, structured)
    end)
  end
end

function M.refresh(buf)
  local data = M.cache[buf]
  if data then
    M.open(buf, data.uri)
  end
end

return M
