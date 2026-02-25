local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local util = require("jira-oil.util")

local M = {}

M.cache = {}

---@param buf number
---@param uri string
function M.open(buf, uri)
  local key = uri:match("^jira%-oil://issue/(.*)$")
  if not key then return end

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"

  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading issue " .. key .. "..." })

  local function render(issue)
    if not vim.api.nvim_buf_is_valid(buf) then return end

    local itype = issue.fields and (issue.fields.issuetype or issue.fields.issueType)
    local lines = {
      "---",
      "Project: " .. (issue.fields and issue.fields.project and issue.fields.project.key or config.options.defaults.project),
      "Type: " .. (itype and itype.name or config.options.defaults.issue_type),
      "Status: " .. (issue.fields and issue.fields.status and issue.fields.status.name or "To Do"),
      "Assignee: " .. (issue.fields and issue.fields.assignee and (issue.fields.assignee.displayName or issue.fields.assignee.name) or "Unassigned"),
      "---",
      "# Summary",
      issue.fields and issue.fields.summary or "",
      "",
      "# Description",
    }

    if issue.fields and issue.fields.description then
      local desc_lines = vim.split(issue.fields.description, "\n")
      for _, l in ipairs(desc_lines) do
        table.insert(lines, l)
      end
    end

    M.cache[buf] = {
      key = key,
      is_new = key == "new",
      original = issue,
    }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].undolevels = old_undolevels

    local km = config.options.keymaps
    vim.keymap.set("n", km.save, function()
      M.save(buf)
    end, { buffer = buf, desc = "Save issue" })
    vim.keymap.set("n", km.close, function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf, desc = "Close issue" })
  end

  if key == "new" then
    render({ fields = {} })
  else
    cli.get_issue(key, function(issue)
      if issue then
        render(issue)
      else
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error loading issue " .. key })
      end
    end)
  end
end

---Parse scratch buffer lines
---@param lines table
---@return table parsed
function M.parse_buffer(lines)
  local parsed = { fields = {}, summary = "", description = "" }
  local section = "frontmatter"
  local content = {}

  for _, line in ipairs(lines) do
    if section == "frontmatter" then
      if line == "---" then
        if next(parsed.fields) then section = "body" end
      else
        local k, v = line:match("^(%w+):%s*(.*)$")
        if k then parsed.fields[string.lower(k)] = util.trim(v) end
      end
    else
      if line:match("^#%s*Summary") then
        section = "summary"
      elseif line:match("^#%s*Description") then
        if section == "summary" then
          parsed.summary = util.trim(table.concat(content, "\n"))
          content = {}
        end
        section = "description"
      else
        table.insert(content, line)
      end
    end
  end

  if section == "summary" then
    parsed.summary = util.trim(table.concat(content, "\n"))
  elseif section == "description" then
    parsed.description = util.trim(table.concat(content, "\n"))
  end

  return parsed
end

---Save scratch buffer to Jira
---@param buf number
function M.save(buf)
  local data = M.cache[buf]
  if not data then return end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local parsed = M.parse_buffer(lines)

  if parsed.summary == "" then
    vim.notify("Summary cannot be empty.", vim.log.levels.ERROR)
    return
  end

  if data.is_new then
    local args = { "issue", "create", "-t", parsed.fields.type, "-s", parsed.summary, "--no-input" }
    local proj = parsed.fields.project
    if proj and proj ~= "" then table.insert(args, "-p"); table.insert(args, proj) end
    if parsed.fields.assignee and parsed.fields.assignee ~= "Unassigned" then table.insert(args, "-a"); table.insert(args, parsed.fields.assignee) end

    -- TODO: Add description if Jira CLI supports it directly via args or body (it supports `--body`? let's check Jira CLI help later)

    cli.exec(args, function(stdout, stderr, code)
      if code ~= 0 then
        vim.notify("Failed to create issue: " .. (stderr or ""), vim.log.levels.ERROR)
      else
        vim.notify("Issue created successfully!", vim.log.levels.INFO)
        vim.bo[buf].modified = false
        -- If we parsed the new key, we could rename the buffer, but for now just leave it.
      end
    end)
  else
    -- Update existing issue
    local args = { "issue", "edit", data.key, "--no-input" }
    if parsed.summary ~= "" then table.insert(args, "-s"); table.insert(args, parsed.summary) end
    -- Assignee change
    local function do_assign()
      if parsed.fields.assignee then
        local assignee = parsed.fields.assignee
        if assignee == "Unassigned" then assignee = "x" end
        cli.exec({ "issue", "assign", data.key, assignee, "--no-input" }, function() end)
      end
    end
    -- Status change
    local function do_status()
      if parsed.fields.status then
        cli.exec({ "issue", "move", data.key, parsed.fields.status, "--no-input" }, function() end)
      end
    end

    cli.exec(args, function(stdout, stderr, code)
      if code ~= 0 then
        vim.notify("Failed to update issue: " .. (stderr or ""), vim.log.levels.ERROR)
      else
        do_assign()
        do_status()
        vim.notify("Issue updated successfully!", vim.log.levels.INFO)
        vim.bo[buf].modified = false
      end
    end)
  end
end

return M
