local config = require("jira-oil.config")
local util = require("jira-oil.util")

local M = {}

---Format a Jira issue as a string for the list buffer.
---The issue key is NOT included -- it is rendered as inline virtual text
---by view.lua.  Only the editable columns defined in config.view.columns
---appear here, separated by " │ ".
---@param issue table Raw issue from CLI
---@return string formatted_line
function M.format_line(issue)
  local cols = config.options.view.columns
  local status_icons = config.options.view.status_icons
  local parts = {}

  for _, col in ipairs(cols) do
    local val = ""
    if col.name == "status" then
      local name = issue.fields and issue.fields.status and issue.fields.status.name or ""
      local icon = util.get_icon(status_icons, name)
      val = icon .. name
    elseif col.name == "type" then
      local itype = issue.fields and (issue.fields.issuetype or issue.fields.issueType)
      local name = itype and itype.name or ""
      local icon = util.get_icon(config.options.view.type_icons, name)
      val = icon .. name
    elseif col.name == "assignee" then
      if issue.fields and issue.fields.assignee then
        val = issue.fields.assignee.displayName or issue.fields.assignee.name or "Unassigned"
      else
        val = "Unassigned"
      end
    elseif col.name == "summary" then
      val = issue.fields and issue.fields.summary or ""
    elseif col.name == "key" then
      -- Kept for backwards compat if someone adds key back into columns
      val = issue.key or ""
    end

    if col.width then
      table.insert(parts, util.pad_right(val, col.width))
    else
      table.insert(parts, val)
    end
  end

  return table.concat(parts, " │ ")
end

---Parse a line from the list buffer into structured data.
---The issue key is NOT extracted from the text -- it comes from extmark
---identity tracking in the mutator / view layer.
---@param line string
---@return table|nil parsed_issue
function M.parse_line(line)
  if util.trim(line) == "" then
    return nil
  end

  local cols = config.options.view.columns
  local parts = vim.split(line, "│", { trimempty = false })

  local parsed = {}

  for i, col in ipairs(cols) do
    local val = parts[i] and util.trim(parts[i]) or ""
    if col.name == "status" then
      -- Strip leading icon character before storing
      parsed.status = util.strip_icon(val)
    elseif col.name == "type" then
      parsed.type = util.strip_icon(val)
    elseif col.name == "assignee" then
      parsed.assignee = val
    elseif col.name == "summary" then
      -- If summary is the last column, rejoin any extra parts
      -- (summary text might contain │)
      if i == #cols then
        -- Rejoin with the same delimiter we split on so spacing is preserved
        val = table.concat(parts, "│", i)
        parsed.summary = util.trim(val)
      else
        parsed.summary = val
      end
    elseif col.name == "key" then
      -- Backwards compat: if key is in columns, parse it
      parsed.key = val
    end
  end

  return parsed
end

return M
