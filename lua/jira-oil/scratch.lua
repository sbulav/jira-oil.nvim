local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local util = require("jira-oil.util")
local actions = require("jira-oil.actions")

local M = {}

M.cache = {}

local function extract_epic_key(value)
  if not value or value == "" then
    return ""
  end
  return value:match("([A-Z0-9]+%-%d+)") or ""
end

local function render_issue(buf, key, issue, is_new)
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local itype = issue.fields and (issue.fields.issuetype or issue.fields.issueType)
  local epic = ""
  if issue.fields and issue.fields.parent and issue.fields.parent.key then
    epic = issue.fields.parent.key
    if issue.fields.parent.fields and issue.fields.parent.fields.summary then
      epic = epic .. ": " .. issue.fields.parent.fields.summary
    end
  elseif issue.fields and config.options.epic_field and config.options.epic_field ~= "" then
    local raw = issue.fields[config.options.epic_field]
    if type(raw) == "string" and raw ~= "" then
      epic = raw
    end
  end
  local epic_key = extract_epic_key(epic)

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
    epic_key = epic_key,
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
  local prefix = field .. ":"
  for i, line in ipairs(lines) do
    if vim.startswith(line, prefix) then
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
  vim.bo[buf].swapfile = false
  vim.b[buf].jira_oil_kind = "issue"

  if not vim.b[buf].jira_oil_keymap_autocmd then
    vim.b[buf].jira_oil_keymap_autocmd = true
    vim.api.nvim_create_autocmd("BufEnter", {
      buffer = buf,
      callback = function()
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            actions.setup_issue(buf)
          end
        end)
      end,
    })
  end

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

---Compute what changed between the original issue and the parsed buffer
---@param data table Cache entry for this buffer
---@param parsed table Parsed buffer content
---@return table changes { summary_changed, assignee_changed, status_changed, epic_changed, new_summary, new_assignee, new_status, new_epic_key }
local function compute_issue_diff(data, parsed)
  local orig = data.original or { fields = {} }
  local changes = {}

  -- Summary
  local orig_summary = orig.fields and orig.fields.summary or ""
  changes.summary_changed = parsed.summary ~= orig_summary
  changes.new_summary = parsed.summary

  -- Assignee
  local orig_assignee = ""
  if orig.fields and orig.fields.assignee then
    orig_assignee = orig.fields.assignee.displayName or orig.fields.assignee.name or ""
  end
  if orig_assignee == "" then orig_assignee = "Unassigned" end
  local new_assignee = parsed.fields.assignee or "Unassigned"
  changes.assignee_changed = new_assignee ~= orig_assignee
  changes.new_assignee = new_assignee

  -- Status
  local orig_status = orig.fields and orig.fields.status and orig.fields.status.name or ""
  local new_status = parsed.fields.status or ""
  changes.status_changed = new_status ~= "" and new_status ~= orig_status
  changes.new_status = new_status

  -- Epic
  local new_epic_key = extract_epic_key(parsed.fields.epic or "")
  local orig_epic_key = data.epic_key or ""
  changes.epic_changed = new_epic_key ~= orig_epic_key
  changes.new_epic_key = new_epic_key
  changes.orig_epic_key = orig_epic_key

  return changes
end

---Execute a sequence of async steps, calling done_cb when all complete
---@param steps table[] Array of { fn = function(next_cb), desc = string }
---@param done_cb function(has_errors: boolean)
local function exec_steps(steps, done_cb)
  local has_errors = false
  local idx = 0

  local function run_next()
    idx = idx + 1
    if idx > #steps then
      done_cb(has_errors)
      return
    end
    steps[idx].fn(function(err)
      if err then has_errors = true end
      run_next()
    end)
  end

  run_next()
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

    if parsed.description and parsed.description ~= "" then
      table.insert(args, "--body")
      table.insert(args, parsed.description)
    end

    cli.exec(args, function(stdout, stderr, code)
      if code ~= 0 then
        vim.notify("Failed to create issue: " .. (stderr or ""), vim.log.levels.ERROR)
      else
        vim.notify("Issue created successfully!", vim.log.levels.INFO)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = false
        end
      end
    end)
  else
    -- Compute diff against original -- only mutate what actually changed
    local diff = compute_issue_diff(data, parsed)

    local steps = {}

    -- Step 1: Edit summary (only if changed)
    if diff.summary_changed then
      table.insert(steps, {
        desc = "update summary",
        fn = function(next_cb)
          local args = { "issue", "edit", data.key, "--no-input", "-s", diff.new_summary }
          cli.exec(args, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update summary for " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              next_cb(true)
            else
              next_cb(false)
            end
          end)
        end,
      })
    end

    -- Step 2: Assign (only if changed)
    if diff.assignee_changed then
      table.insert(steps, {
        desc = "update assignee",
        fn = function(next_cb)
          local assignee = diff.new_assignee
          if assignee == "Unassigned" then assignee = "x" end
          cli.exec({ "issue", "assign", data.key, assignee }, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update assignee for " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              next_cb(true)
            else
              next_cb(false)
            end
          end)
        end,
      })
    end

    -- Step 3: Move status (only if changed)
    if diff.status_changed then
      table.insert(steps, {
        desc = "update status",
        fn = function(next_cb)
          cli.exec({ "issue", "move", data.key, diff.new_status }, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update status for " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              next_cb(true)
            else
              next_cb(false)
            end
          end)
        end,
      })
    end

    -- Step 4: Epic change (only if changed)
    if diff.epic_changed then
      -- If there was an old epic, remove it first, then add new one
      if diff.orig_epic_key ~= "" then
        table.insert(steps, {
          desc = "remove old epic",
          fn = function(next_cb)
            cli.exec({ "epic", "remove", data.key }, function(_, stderr, code)
              if code ~= 0 then
                vim.notify("Failed to remove epic from " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
                next_cb(true)
              else
                next_cb(false)
              end
            end)
          end,
        })
      end
      if diff.new_epic_key ~= "" then
        table.insert(steps, {
          desc = "add new epic",
          fn = function(next_cb)
            cli.exec({ "epic", "add", diff.new_epic_key, data.key }, function(_, stderr, code)
              if code ~= 0 then
                vim.notify("Failed to add epic to " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
                next_cb(true)
              else
                next_cb(false)
              end
            end)
          end,
        })
      end
    end

    if #steps == 0 then
      vim.notify("No changes to apply.", vim.log.levels.INFO)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
      end
      return
    end

    exec_steps(steps, function(has_errors)
      if has_errors then
        vim.notify("Some updates failed for " .. data.key .. ". Check messages above.", vim.log.levels.WARN)
      else
        -- Update cached epic key on success
        if diff.epic_changed then
          data.epic_key = diff.new_epic_key
        end
        vim.notify("Issue " .. data.key .. " updated successfully!", vim.log.levels.INFO)
      end
      if vim.api.nvim_buf_is_valid(buf) then
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
