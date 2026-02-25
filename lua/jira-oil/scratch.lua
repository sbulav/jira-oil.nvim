local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local util = require("jira-oil.util")
local actions = require("jira-oil.actions")

local M = {}

M.cache = {}

local function render_issue(buf, key, issue, is_new)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local itype = issue.fields and (issue.fields.issuetype or issue.fields.issueType)
  local epic = ""
  if issue.fields and issue.fields.parent and issue.fields.parent.key then
    epic = issue.fields.parent.key
    if issue.fields.parent.fields and issue.fields.parent.fields.summary then
      epic = epic .. ": " .. issue.fields.parent.fields.summary
    end
  end

  local components = ""
  if issue.fields and issue.fields.components and type(issue.fields.components) == "table" then
    local names = {}
    for _, comp in ipairs(issue.fields.components) do
      if comp and comp.name and comp.name ~= "" then
        table.insert(names, comp.name)
      end
    end
    components = table.concat(names, ", ")
  end

  local status = issue.fields and issue.fields.status and issue.fields.status.name or ""
  if status == "" then
    status = config.options.defaults.status
  end

  local assignee = ""
  if issue.fields and issue.fields.assignee then
    assignee = issue.fields.assignee.displayName or issue.fields.assignee.name or ""
  end
  if assignee == "" then
    if is_new and config.options.defaults.assignee ~= "" then
      assignee = config.options.defaults.assignee
    else
      assignee = "Unassigned"
    end
  end

  local lines = {
    "---",
    "Project: " .. (issue.fields and issue.fields.project and issue.fields.project.key or config.options.defaults.project),
    "Epic: " .. epic,
    "Type: " .. (itype and itype.name or config.options.defaults.issue_type),
    "Components: " .. components,
    "Status: " .. status,
    "Assignee: " .. assignee,
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
    is_new = is_new,
    original = issue,
  }

  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = old_undolevels

  actions.setup_issue(buf)
end

local function find_field_line(buf, field)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^" .. field .. ":") then
      return i
    end
  end
  return nil
end

local function update_field(buf, field, value)
  local line_nr = find_field_line(buf, field)
  if line_nr then
    vim.api.nvim_buf_set_lines(buf, line_nr - 1, line_nr, false, { string.format("%s: %s", field, value) })
  end
end

local function pick_epic(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  cli.get_epics(function(epics)
    if not epics or #epics == 0 then
      vim.notify("No epics found.", vim.log.levels.WARN)
      return
    end

    local items = {}
    local by_label = {}
    for _, epic in ipairs(epics) do
      local label = epic.key
      if epic.summary and epic.summary ~= "" then
        label = label .. ": " .. epic.summary
      end
      by_label[label] = epic
      table.insert(items, label)
    end

    vim.ui.select(items, { prompt = "Select Epic" }, function(choice)
      if not choice then
        return
      end
      update_field(buf, "Epic", choice)
    end)
  end)
end

local function pick_components(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local components = config.options.create.available_components or {}
  if #components == 0 then
    vim.notify("No components configured in jira-oil.create.available_components", vim.log.levels.WARN)
    return
  end

  local line_nr = find_field_line(buf, "Components")
  local current_value = ""
  if line_nr then
    local lines = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)
    current_value = lines[1]:gsub("^Components:%s*", "")
  end

  local selected = {}
  for comp in current_value:gmatch("[^,]+") do
    comp = vim.trim(comp)
    if comp ~= "" then
      selected[comp] = true
    end
  end

  local function update_line()
    local ordered = {}
    for _, comp in ipairs(components) do
      if selected[comp] then
        table.insert(ordered, comp)
      end
    end
    update_field(buf, "Components", table.concat(ordered, ", "))
  end

  local function open_picker()
    local items = {}
    for _, comp in ipairs(components) do
      local prefix = selected[comp] and "✓ " or "  "
      table.insert(items, prefix .. comp)
    end

    vim.ui.select(items, { prompt = "Select Components (Enter toggles, Esc finishes)" }, function(choice)
      if not choice then
        update_line()
        return
      end
      local comp = choice:gsub("^%s*✓%s+", "")
      comp = vim.trim(comp)
      if comp ~= "" then
        selected[comp] = not selected[comp]
      end
      open_picker()
    end)
  end

  open_picker()
end

---@param buf number
---@param uri string
function M.open(buf, uri)
  local key = uri:match("^jira%-oil://issue/(.*)$")
  if not key then return end

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].jira_oil_kind = "issue"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading issue " .. key .. "..." })

  if key == "new" then
    render_issue(buf, key, { fields = {} }, true)
  else
    cli.get_issue(key, function(issue)
      if issue then
        render_issue(buf, key, issue, false)
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
    local itype = parsed.fields.type ~= "" and parsed.fields.type or config.options.defaults.issue_type
    local args = { "issue", "create", "-t", itype, "-s", parsed.summary, "--no-input" }
    local proj = parsed.fields.project
    if proj and proj ~= "" then table.insert(args, "-p"); table.insert(args, proj) end
    if parsed.fields.assignee and parsed.fields.assignee ~= "Unassigned" and parsed.fields.assignee ~= "" then
      local assignee = parsed.fields.assignee
      if assignee == "me" and vim.env.JIRA_USER and vim.env.JIRA_USER ~= "" then
        assignee = vim.env.JIRA_USER
      end
      if assignee ~= "me" and assignee ~= "" then
        table.insert(args, "-a")
        table.insert(args, assignee)
      end
    end

    if parsed.fields.epic and parsed.fields.epic ~= "" then
      local epic_key = parsed.fields.epic:match("^([A-Z0-9]+%-%d+)")
      if epic_key then
        table.insert(args, "-P")
        table.insert(args, epic_key)
      end
    end

    if parsed.fields.components and parsed.fields.components ~= "" then
      for comp in string.gmatch(parsed.fields.components, "[^,]+") do
        comp = vim.trim(comp)
        if comp ~= "" then
          table.insert(args, "-C")
          table.insert(args, comp)
        end
      end
    end

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

function M.reset(buf)
  local data = M.cache[buf]
  if not data then return end
  local issue = data.original or { fields = {} }
  render_issue(buf, data.key, issue, data.is_new)
end

function M.pick_epic(buf)
  pick_epic(buf)
end

function M.pick_components(buf)
  pick_components(buf)
end

return M
