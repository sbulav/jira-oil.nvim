local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local util = require("jira-oil.util")
local actions = require("jira-oil.actions")

local M = {}

M.cache = {}
M.pending_prefill = nil
M.pending_existing = {}
M.drafts = {}
M.ns = vim.api.nvim_create_namespace("JiraOilIssue")
M.ns_anchor = vim.api.nvim_create_namespace("JiraOilIssueAnchor")

---@param key string
---@return boolean
local function has_draft_for_key(key)
  return key and key ~= "" and M.drafts[key] ~= nil
end

---@param buf number
local function apply_issue_winbar(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local data = M.cache[buf]
  if not data then
    return
  end

  local title = "Jira Issue"
  if data.key == "new" then
    title = "Jira Issue:  NEW"
  elseif data.key and data.key ~= "" then
    title = "Jira Issue:  " .. data.key
  end

  if not data.is_new and has_draft_for_key(data.key) then
    title = title .. " [draft]"
  end

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local textoff = 0
    local info = vim.fn.getwininfo(win)
    if info and info[1] and info[1].textoff then
      textoff = tonumber(info[1].textoff) or 0
    end
    vim.wo[win].winbar = string.rep(" ", textoff) .. title
  end
end

---@param key string
local function refresh_winbar_for_key(key)
  if not key or key == "" then
    return
  end
  for buf, data in pairs(M.cache) do
    if data and data.key == key and vim.api.nvim_buf_is_valid(buf) then
      apply_issue_winbar(buf)
    end
  end
end

---@param key string|nil
local function refresh_list_draft_markers(key)
  local ok, view = pcall(require, "jira-oil.view")
  if not ok or not view or not view.cache then
    return
  end

  if key and key ~= "" and view.update_draft_marker_for_key then
    view.update_draft_marker_for_key(key)
    return
  end

  for buf, data in pairs(view.cache) do
    if data and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].jira_oil_kind == "list" then
      view.decorate_current(buf)
    end
  end
end

local function build_issue_from_prefill(prefill, source_issue)
  local issue = vim.deepcopy(source_issue or { fields = {} })
  issue.fields = issue.fields or {}

  local row = prefill and prefill.row_fields or {}
  if row.summary and row.summary ~= "" then
    issue.fields.summary = row.summary
  end

  if row.assignee and row.assignee ~= "" then
    if row.assignee == "Unassigned" then
      issue.fields.assignee = nil
    else
      issue.fields.assignee = { displayName = row.assignee }
    end
  end

  if row.status and row.status ~= "" then
    issue.fields.status = { name = row.status }
  end

  if row.type and row.type ~= "" then
    issue.fields.issuetype = { name = row.type }
    issue.fields.issueType = issue.fields.issuetype
  end

  if not issue.fields.project or not issue.fields.project.key or issue.fields.project.key == "" then
    local source_project = util.issue_project_from_key(prefill and prefill.source_key)
    issue.fields.project = { key = source_project or config.options.defaults.project }
  end

  return issue
end

---@param issue table
---@param row table|nil
local function apply_row_overrides(issue, row)
  if not row then
    return
  end
  issue.fields = issue.fields or {}

  if row.summary and row.summary ~= "" then
    issue.fields.summary = row.summary
  end

  if row.assignee and row.assignee ~= "" then
    if row.assignee == "Unassigned" then
      issue.fields.assignee = nil
    else
      issue.fields.assignee = { displayName = row.assignee }
    end
  end

  if row.status and row.status ~= "" then
    issue.fields.status = { name = row.status }
  end

  if row.type and row.type ~= "" then
    issue.fields.issuetype = { name = row.type }
    issue.fields.issueType = issue.fields.issuetype
  end
end

---@param issue table
---@param parsed table|nil
local function apply_parsed_overrides(issue, parsed)
  if not parsed then
    return
  end
  issue.fields = issue.fields or {}

  if parsed.summary and parsed.summary ~= "" then
    issue.fields.summary = parsed.summary
  end

  if parsed.fields then
    local status = parsed.fields.status or ""
    if status ~= "" then
      issue.fields.status = { name = status }
    end

    local assignee = parsed.fields.assignee or ""
    if assignee ~= "" then
      if assignee == "Unassigned" then
        issue.fields.assignee = nil
      else
        issue.fields.assignee = { displayName = assignee }
      end
    end

    local itype = parsed.fields.type or ""
    if itype ~= "" then
      issue.fields.issuetype = { name = itype }
      issue.fields.issueType = issue.fields.issuetype
    end

    local comps = parsed.fields.components or ""
    if comps ~= "" then
      local list = {}
      for comp in string.gmatch(comps, "[^,]+") do
        comp = vim.trim(comp)
        if comp ~= "" then
          table.insert(list, { name = comp })
        end
      end
      issue.fields.components = list
    end
  end

  issue.fields.description = parsed.description or ""
end

local function define_highlights()
  vim.api.nvim_set_hl(0, "JiraOilIssueLabel", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "JiraOilIssueDivider", { link = "WinSeparator", default = true })
  vim.api.nvim_set_hl(0, "JiraOilIssueValue", { link = "Normal", default = true })
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("JiraOilIssueHighlights", { clear = true }),
  callback = define_highlights,
})

local function extract_epic_key(value)
  if not value or value == "" then
    return ""
  end
  return value:match("([A-Z0-9]+%-%d+)") or ""
end

local function get_field_row(buf, field)
  local data = M.cache[buf]
  if not data or not data.layout or not data.layout.anchors then
    return nil
  end
  local id = data.layout.anchors[string.lower(field)]
  if not id then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns_anchor, id, {})
  if not pos or #pos == 0 then
    return nil
  end
  return pos[1] + 1
end

local function apply_issue_decorations(buf)
  local data = M.cache[buf]
  if not data or not data.layout or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  local label_width = data.layout.label_width or 12

  local function add_label(field, hl)
    local row = get_field_row(buf, field)
    if not row then
      return
    end
    local label = util.pad_right(field .. ":", label_width) .. " "
    vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, 0, {
      virt_text = { { label, hl or "JiraOilIssueLabel" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end

  add_label("Project")
  add_label("Epic")
  add_label("Type")
  add_label("Components")
  add_label("Status")
  add_label("Assignee")
  add_label("Summary")
  add_label("Description")

  for _, divider in ipairs({ "divider1", "divider2" }) do
    local row = get_field_row(buf, divider)
    if row then
      vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, 0, {
        virt_text = { { string.rep("-", label_width + 24), "JiraOilIssueDivider" } },
        virt_text_pos = "overlay",
      })
    end
  end
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

  local project = issue.fields and issue.fields.project and issue.fields.project.key or config.options.defaults.project
  local summary = issue.fields and issue.fields.summary or ""

  local desc_lines = { "" }
  if issue.fields and issue.fields.description and issue.fields.description ~= "" then
    desc_lines = vim.split(issue.fields.description, "\n")
  end

  local lines = {
    project,
    epic,
    (itype and itype.name or config.options.defaults.issue_type),
    components,
    status,
    assignee,
    "",
    summary,
    "",
  }
  for _, l in ipairs(desc_lines) do
    table.insert(lines, l)
  end

  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = old_undolevels

  M.cache[buf] = {
    key = key,
    is_new = is_new,
    original = issue,
    epic_key = epic_key,
    layout = {
      label_width = 12,
      anchors = {},
    },
  }

  -- Seed stable field anchors in a dedicated namespace that is never cleared
  -- by visual decoration refreshes.
  vim.api.nvim_buf_clear_namespace(buf, M.ns_anchor, 0, -1)
  local anchors = M.cache[buf].layout.anchors
  anchors.project = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 0, 0, { right_gravity = false })
  anchors.epic = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 1, 0, { right_gravity = false })
  anchors.type = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 2, 0, { right_gravity = false })
  anchors.components = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 3, 0, { right_gravity = false })
  anchors.status = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 4, 0, { right_gravity = false })
  anchors.assignee = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 5, 0, { right_gravity = false })
  anchors.divider1 = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 6, 0, { right_gravity = false })
  anchors.summary = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 7, 0, { right_gravity = false })
  anchors.divider2 = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 8, 0, { right_gravity = false })
  anchors.description = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 9, 0, { right_gravity = false })

  apply_issue_decorations(buf)
  apply_issue_winbar(buf)
  actions.setup_issue(buf)
end

local function update_field(buf, field, value)
  local row = get_field_row(buf, field)
  if row then
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, #line, { value })
    apply_issue_decorations(buf)
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

  local line_nr = get_field_row(buf, "Components")
  local current_value = ""
  if line_nr then
    local lines = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)
    current_value = util.trim(lines[1] or "")
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
  vim.bo[buf].filetype = "jira-oil-issue"
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
    local prefill = M.pending_prefill
    M.pending_prefill = nil
    if prefill and prefill.source_key and prefill.source_key ~= "" then
      cli.get_issue(prefill.source_key, function(source_issue)
        local issue = build_issue_from_prefill(prefill, source_issue)
        render_issue(buf, key, issue, true)
      end)
    else
      local issue = build_issue_from_prefill(prefill or {}, nil)
      render_issue(buf, key, issue, true)
    end
  else
    local pending = M.pending_existing[key]
    M.pending_existing[key] = nil
    local draft = M.drafts[key]
    cli.get_issue(key, function(issue)
      if issue then
        apply_row_overrides(issue, pending and pending.row_fields or nil)
        apply_parsed_overrides(issue, draft and draft.parsed or nil)
        render_issue(buf, key, issue, false)
      else
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error loading issue " .. key })
      end
    end)
  end
end

---@param key string
---@param row_fields table|nil
function M.open_existing(key, row_fields)
  M.pending_existing[key] = {
    row_fields = row_fields,
  }
  vim.cmd.edit("jira-oil://issue/" .. key)
end

---@param prefill table|nil
function M.open_new(prefill)
  M.pending_prefill = prefill
  vim.cmd.edit("jira-oil://issue/new")
end

---Parse scratch buffer into a structured issue payload.
---If passed a buffer number, parse using stable field anchors (extmarks).
---If passed a raw line table, use the legacy parser as fallback.
---@param input number|table
---@return table parsed
function M.parse_buffer(input)
  local parsed = { fields = {}, summary = "", description = "" }

  if type(input) == "number" then
    local buf = input
    local data = M.cache[buf]
    if not data or not data.layout then
      return parsed
    end

    local function get_value(field)
      local row = get_field_row(buf, field)
      if not row then
        return ""
      end
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      return util.trim(line)
    end

    parsed.fields.project = get_value("Project")
    parsed.fields.epic = get_value("Epic")
    parsed.fields.type = get_value("Type")
    parsed.fields.components = get_value("Components")
    parsed.fields.status = get_value("Status")
    parsed.fields.assignee = get_value("Assignee")
    parsed.summary = get_value("Summary")

    local desc_row = get_field_row(buf, "Description")
    if desc_row then
      local desc_lines = vim.api.nvim_buf_get_lines(buf, desc_row - 1, -1, false)
      parsed.description = util.trim(table.concat(desc_lines, "\n"))
    end

    return parsed
  end

  -- Legacy fallback parser for raw line tables
  local lines = input or {}
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
---@return table changes
local function compute_issue_diff(data, parsed)
  local orig = data.original or { fields = {} }
  local changes = {}

  -- Summary
  local orig_summary = orig.fields and orig.fields.summary or ""
  changes.summary_changed = parsed.summary ~= orig_summary
  changes.new_summary = parsed.summary

  -- Description
  local orig_description = orig.fields and orig.fields.description or ""
  changes.description_changed = parsed.description ~= orig_description
  changes.new_description = parsed.description

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

  -- Components
  local orig_components = {}
  if orig.fields and orig.fields.components and type(orig.fields.components) == "table" then
    for _, comp in ipairs(orig.fields.components) do
      if comp and comp.name and comp.name ~= "" then
        table.insert(orig_components, comp.name)
      end
    end
  end
  local orig_components_str = table.concat(orig_components, ", ")
  local new_components_str = parsed.fields.components or ""
  changes.components_changed = new_components_str ~= orig_components_str
  changes.new_components = new_components_str

  -- Type
  local orig_type = ""
  if orig.fields then
    local itype = orig.fields.issuetype or orig.fields.issueType
    if itype then orig_type = itype.name or "" end
  end
  local new_type = parsed.fields.type or ""
  changes.type_changed = new_type ~= "" and new_type ~= orig_type
  changes.new_type = new_type

  return changes
end

---@param diff table
---@return boolean
local function has_any_changes(diff)
  return diff.summary_changed
    or diff.description_changed
    or diff.assignee_changed
    or diff.status_changed
    or diff.epic_changed
    or diff.components_changed
    or diff.type_changed
end

---@param key string
---@return table|nil
function M.get_draft(key)
  local draft = M.drafts[key]
  if not draft then
    return nil
  end
  return vim.deepcopy(draft)
end

---@param key string
---@return boolean
function M.has_draft(key)
  return has_draft_for_key(key)
end

---@param key string
---@return table|nil
function M.peek_draft(key)
  return M.drafts[key]
end

---@return string[]
function M.get_draft_keys()
  local keys = {}
  for key, _ in pairs(M.drafts) do
    table.insert(keys, key)
  end
  return keys
end

---@return table<string, table>
function M.get_all_drafts()
  return vim.deepcopy(M.drafts)
end

---@param key string
function M.clear_draft(key)
  M.drafts[key] = nil
  refresh_winbar_for_key(key)
  refresh_list_draft_markers(key)
end

function M.clear_all_drafts()
  local keys = {}
  for key, _ in pairs(M.drafts) do
    table.insert(keys, key)
  end
  M.drafts = {}
  for _, key in ipairs(keys) do
    refresh_winbar_for_key(key)
    refresh_list_draft_markers(key)
  end
end

---@param buf number
function M.capture_draft(buf)
  local data = M.cache[buf]
  if not data or not data.key or data.key == "" or data.key == "new" then
    return
  end

  local parsed = M.parse_buffer(buf)
  local diff = compute_issue_diff(data, parsed)
  if has_any_changes(diff) then
    M.drafts[data.key] = {
      parsed = parsed,
      diff = diff,
    }
  else
    M.drafts[data.key] = nil
  end
  refresh_winbar_for_key(data.key)
  refresh_list_draft_markers(data.key)
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

  local parsed = M.parse_buffer(buf)

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
      local src_assignee = data.original and data.original.fields and data.original.fields.assignee or nil
      local assignee = util.resolve_assignee_for_cli(parsed.fields.assignee, src_assignee)
      if assignee == "me" and vim.env.JIRA_USER and vim.env.JIRA_USER ~= "" then
        assignee = vim.env.JIRA_USER
      end
      if assignee and assignee ~= "me" and assignee ~= "" then
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
        local created_key = util.extract_issue_key((stdout or "") .. "\n" .. (stderr or ""))
        if created_key and created_key ~= "" then
          data.key = created_key
          data.is_new = false
          data.epic_key = extract_epic_key(parsed.fields.epic or "")
          if not data.original then
            data.original = { fields = {} }
          end
          if not data.original.fields then
            data.original.fields = {}
          end
          data.original.fields.summary = parsed.summary
          data.original.fields.description = parsed.description
          if parsed.fields.assignee and parsed.fields.assignee ~= "" and parsed.fields.assignee ~= "Unassigned" then
            data.original.fields.assignee = { displayName = parsed.fields.assignee }
          else
            data.original.fields.assignee = nil
          end
          if parsed.fields.status and parsed.fields.status ~= "" then
            data.original.fields.status = { name = parsed.fields.status }
          end
          if parsed.fields.type and parsed.fields.type ~= "" then
            data.original.fields.issuetype = { name = parsed.fields.type }
          end
          if parsed.fields.components and parsed.fields.components ~= "" then
            local comps = {}
            for comp in string.gmatch(parsed.fields.components, "[^,]+") do
              comp = vim.trim(comp)
              if comp ~= "" then
                table.insert(comps, { name = comp })
              end
            end
            data.original.fields.components = comps
          end
          if parsed.fields.project and parsed.fields.project ~= "" then
            data.original.fields.project = { key = parsed.fields.project }
          end
          vim.api.nvim_buf_set_name(buf, "jira-oil://issue/" .. created_key)
          cli.clear_cache("all")
          vim.notify("Issue created successfully: " .. created_key, vim.log.levels.INFO)
        else
          cli.clear_cache("all")
          vim.notify("Issue created successfully!", vim.log.levels.INFO)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].modified = false
        end
      end
    end)
  else
    -- Compute diff against original -- only mutate what actually changed
    local diff = compute_issue_diff(data, parsed)

    local steps = {}

    -- Step 1: Edit summary and/or description (combined into one `jira issue edit` call)
    if diff.summary_changed or diff.description_changed then
      table.insert(steps, {
        desc = "update summary/description",
        fn = function(next_cb)
          local args = { "issue", "edit", data.key, "--no-input" }
          if diff.summary_changed then
            table.insert(args, "-s")
            table.insert(args, diff.new_summary)
          end
          if diff.description_changed then
            table.insert(args, "--body")
            table.insert(args, diff.new_description)
          end
          cli.exec(args, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
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

    -- Step 5: Components change (only if changed)
    if diff.components_changed then
      table.insert(steps, {
        desc = "update components",
        fn = function(next_cb)
          -- jira issue edit supports --component/-C to set components
          local args = { "issue", "edit", data.key, "--no-input" }
          if diff.new_components == "" then
            -- Clear components by passing empty component flag
            table.insert(args, "--component")
            table.insert(args, "")
          else
            for comp in string.gmatch(diff.new_components, "[^,]+") do
              comp = vim.trim(comp)
              if comp ~= "" then
                table.insert(args, "--component")
                table.insert(args, comp)
              end
            end
          end
          cli.exec(args, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update components for " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              next_cb(true)
            else
              next_cb(false)
            end
          end)
        end,
      })
    end

    -- Step 6: Type change (only if changed)
    if diff.type_changed then
      table.insert(steps, {
        desc = "update type",
        fn = function(next_cb)
          -- jira issue edit supports --type/-t to change issue type
          cli.exec({ "issue", "edit", data.key, "--no-input", "-t", diff.new_type }, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update type for " .. data.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              next_cb(true)
            else
              next_cb(false)
            end
          end)
        end,
      })
    end

    if #steps == 0 then
      vim.notify("No changes to apply.", vim.log.levels.INFO)
      M.clear_draft(data.key)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
      end
      return
    end

    exec_steps(steps, function(has_errors)
      if has_errors then
        vim.notify("Some updates failed for " .. data.key .. ". Check messages above.", vim.log.levels.WARN)
      else
        -- Update cached original to reflect saved state so re-saving
        -- without changes correctly reports "no changes to apply"
        local orig = data.original
        if not orig.fields then orig.fields = {} end
        if diff.summary_changed then
          orig.fields.summary = diff.new_summary
        end
        if diff.description_changed then
          orig.fields.description = diff.new_description
        end
        if diff.assignee_changed then
          if diff.new_assignee == "Unassigned" then
            orig.fields.assignee = nil
          else
            orig.fields.assignee = { displayName = diff.new_assignee }
          end
        end
        if diff.status_changed then
          orig.fields.status = { name = diff.new_status }
        end
        if diff.epic_changed then
          data.epic_key = diff.new_epic_key
        end
        if diff.components_changed then
          local comps = {}
          for comp in string.gmatch(diff.new_components, "[^,]+") do
            comp = vim.trim(comp)
            if comp ~= "" then
              table.insert(comps, { name = comp })
            end
          end
          orig.fields.components = comps
        end
        if diff.type_changed then
          local itype = orig.fields.issuetype or orig.fields.issueType
          if itype then
            itype.name = diff.new_type
          else
            orig.fields.issuetype = { name = diff.new_type }
          end
        end
        vim.notify("Issue " .. data.key .. " updated successfully!", vim.log.levels.INFO)
        cli.clear_cache("all")
        M.clear_draft(data.key)
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
  if not data.is_new and data.key and data.key ~= "" then
    M.clear_draft(data.key)
  end
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
