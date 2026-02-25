local config = require("jira-oil.config")
local util = require("jira-oil.util")

local M = {}

---Format a Jira issue as a string for the list buffer
---@param issue table Raw issue from CLI
---@return string formatted_line
function M.format_line(issue)
  local cols = config.options.view.columns
  local parts = {}

  for _, col in ipairs(cols) do
    local val = ""
    if col.name == "key" then
      val = issue.key or ""
    elseif col.name == "status" then
      val = issue.fields and issue.fields.status and issue.fields.status.name or ""
    elseif col.name == "type" then
      local itype = issue.fields and (issue.fields.issuetype or issue.fields.issueType)
      val = itype and itype.name or ""
    elseif col.name == "assignee" then
      if issue.fields and issue.fields.assignee then
        val = issue.fields.assignee.displayName or issue.fields.assignee.name or "Unassigned"
      else
        val = "Unassigned"
      end
    elseif col.name == "summary" then
      val = issue.fields and issue.fields.summary or ""
    end

    if col.width then
      table.insert(parts, util.pad_right(val, col.width))
    else
      table.insert(parts, val)
    end
  end

  return table.concat(parts, " │ ")
end

---Parse a string from the list buffer into structured data
---@param line string
---@return table|nil parsed_issue
function M.parse_line(line)
  if util.trim(line) == "" then
    return nil
  end

  local cols = config.options.view.columns
  local parts = vim.split(line, "│", { trimempty = false })

  local parsed = {}
  local is_new = true

  for i, col in ipairs(cols) do
    local val = parts[i] and util.trim(parts[i]) or ""
    if col.name == "key" then
      parsed.key = val
      if val:match("^[A-Z][A-Z0-9]*%-[0-9]+$") then
        is_new = false
      end
    elseif col.name == "status" then
      parsed.status = val
    elseif col.name == "type" then
      parsed.type = val
    elseif col.name == "assignee" then
      parsed.assignee = val
    elseif col.name == "summary" then
      -- If summary is the last column, we might have merged extra parts if summary contained '│'
      if i == #cols then
        val = table.concat(parts, " │ ", i)
        parsed.summary = util.trim(val)
      else
        parsed.summary = val
      end
    end
  end

  -- If no key, it's a new issue to create
  if is_new then
    parsed.is_new = true
    -- Assign defaults if not set
    if parsed.type == "" then parsed.type = config.options.defaults.issue_type end
    if parsed.assignee == "" then parsed.assignee = config.options.defaults.assignee end
    if parsed.status == "" then parsed.status = "To Do" end
    -- The summary might be typed in the first column by mistake, let's fix that
    if parsed.key and parsed.key ~= "" and not parsed.key:match("^[A-Z][A-Z0-9]*%-[0-9]+$") then
      if parsed.summary == "" then
        parsed.summary = parsed.key
        parsed.key = ""
      end
    end
  end

  return parsed
end

return M
