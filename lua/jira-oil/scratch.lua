local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local util = require("jira-oil.util")
local actions = require("jira-oil.actions")
local custom = require("jira-oil.custom_fields")

local M = {}

M.cache = {}
M.pending_prefill = nil
M.pending_existing = {}
M.drafts = {}
M.ns = vim.api.nvim_create_namespace("JiraOilIssue")
M.ns_anchor = vim.api.nvim_create_namespace("JiraOilIssueAnchor")
local saving_issues = {}

---Reserve existing issues until the list or editor finishes writing them.
function M.reserve_updates(keys)
  for _, key in ipairs(keys) do
    if saving_issues[key] then
      vim.notify("A Jira save is already in progress for " .. key .. ".", vim.log.levels.WARN)
      return nil
    end
  end
  for _, key in ipairs(keys) do saving_issues[key] = true end
  return function()
    for _, key in ipairs(keys) do saving_issues[key] = nil end
  end
end

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

  if row.labels and row.labels ~= "" then
    issue.fields.labels = util.labels_to_list(row.labels)
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

  if row.labels ~= nil then
    issue.fields.labels = util.labels_to_list(row.labels)
  end
end

---@param issue table
---@param draft table|nil
local function apply_parsed_overrides(issue, draft)
  if not (draft and draft.parsed) then
    return
  end
  local parsed, diff = draft.parsed, draft.diff
  issue.fields = issue.fields or {}

  local fields = parsed.fields or {}
  apply_row_overrides(issue, {
    summary = diff.summary_changed and parsed.summary or nil,
    status = diff.status_changed and fields.status or nil,
    assignee = diff.assignee_changed and fields.assignee or nil,
    type = diff.type_changed and fields.type or nil,
    labels = diff.labels_changed and fields.labels or nil,
  })
  if diff.summary_changed then issue.fields.summary = parsed.summary end
  if diff.description_changed then issue.fields.description = parsed.description end
  if diff.components_changed then
    issue.fields.components = {}
    for _, name in ipairs(util.labels_to_list(fields.components)) do
      table.insert(issue.fields.components, { name = name })
    end
  end
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

local extract_epic_key = util.extract_epic_key


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
  -- Protect anchor namespace by making it read-only
  -- vim.api.nvim_buf_set_extmark supports strict=false, readonly=true in nvim 0.10+
  -- But we need to use a separate namespace and add it to the buf.

  local label_width = data.layout.label_width or 12

  local function add_label(field, hl, label_text)
    local row = get_field_row(buf, field)
    if not row then
      return
    end
    local label = util.pad_right((label_text or field) .. ":", label_width) .. " "
    
    -- In Nvim 0.10+ we can use invalidate = false or similar to keep the label
    vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, 0, {
      virt_text = { { label, hl or "JiraOilIssueLabel" } },
      virt_text_pos = "inline",
      right_gravity = false,
      -- strict = false, -- nvim 0.10+ feature
    })
  end

  add_label("Project")
  add_label("Epic")
  add_label("Type")
  add_label("Components")
  add_label("Labels")
  add_label("Status")
  add_label("Assignee")
  for _, field in ipairs(data.custom_field_defs or {}) do
    add_label("custom:" .. field.id, nil, custom.label(field))
  end
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

local function extract_adf_text(node)
  local out = {}
  if type(node) ~= "table" then return out end
  if node.type == "text" and type(node.text) == "string" then
    table.insert(out, node.text)
  end
  -- Handle block nodes where one CR is enough (e.g. listItem, hardBreak)
  if node.type == "hardBreak" or node.type == "listItem" then
    table.insert(out, "\n")
  end
  -- Handle block nodes where an empty line would indicate a break:
  -- paragraph, heading, etc.
  if node.type == "paragraph" or node.type == "heading" then
    table.insert(out, "\n\n")
  end
  for _, child in ipairs(node.content or {}) do
    vim.list_extend(out, extract_adf_text(child))
  end
  return out
end

--- Strip trailing whitespace per line and surrounding blank space, so
--- whitespace-only differences don't count as description edits.
---@param text string
---@return string
local function normalize_description(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%s+$", "")
  end
  return util.trim(table.concat(lines, "\n"))
end

local function components_text(fields)
  local names = {}
  for _, component in ipairs(type(fields.components) == "table" and fields.components or {}) do
    if type(component) == "table" and component.name then table.insert(names, component.name) end
  end
  return util.labels_to_string(names)
end

---@param desc any string or ADF document
---@return string[]
local function description_lines(desc)
  if type(desc) == "string" and desc ~= "" then
    return vim.split(desc, "\n")
  elseif type(desc) == "table" then
    local full = table.concat(extract_adf_text(desc)):gsub("^\n+", ""):gsub("\n+$", "")
    if full ~= "" then
      return vim.split(full, "\n")
    end
  end
  return { "" }
end

local function render_issue(buf, key, issue, is_new, opts)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  opts = opts or {}
  local original = opts.original or issue
  local draft = opts.draft
  local parsed = draft and draft.parsed
  local custom_text = parsed and parsed.custom_fields

  local itype = issue.fields and (issue.fields.issuetype or issue.fields.issueType)
  local original_epic = opts.original_epic or util.resolve_epic_from_fields(original.fields)
  local epic = parsed and draft.diff.epic_changed and parsed.fields.epic or original_epic

  local components = components_text(issue.fields or {})

  local labels = util.labels_to_string(issue.fields and issue.fields.labels or "")

  local status = issue.fields and issue.fields.status and issue.fields.status.name or ""
  if status == "" then
    status = config.options.defaults.status
  end

  local assignee = ""
  if issue.fields and type(issue.fields.assignee) == "table" then
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

  local desc_lines = description_lines(issue.fields and issue.fields.description)

  local definitions = vim.deepcopy(parsed and parsed.custom_field_defs or config.options.custom_fields)
  local lines = { project, epic, (itype and itype.name or config.options.defaults.issue_type), components, labels, status, assignee }
  local field_rows, original_custom_fields, read_errors = {}, {}, {}
  local label_width = 12
  for _, field in ipairs(definitions) do
    local text = custom.display(field, issue.fields and issue.fields[field.id])
    local baseline, err = custom.display(field, original.fields and original.fields[field.id])
    original_custom_fields[field.id], read_errors[field.id] = baseline, err
    if custom_text and custom_text[field.id] ~= nil then text = custom_text[field.id] end
    field_rows["custom:" .. field.id] = #lines
    label_width = math.max(label_width, vim.api.nvim_strwidth(custom.label(field)) + 1)
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  end
  local divider_row = #lines
  vim.list_extend(lines, { "", summary, "" })
  vim.list_extend(lines, desc_lines)

  util.without_undo(buf, function()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
  end)

  M.cache[buf] = {
    key = key,
    is_new = is_new,
    original = original,
    -- The original description as it renders in the buffer: the baseline for
    -- change detection, since ADF flattening is lossy.
    original_description = normalize_description(
      table.concat(description_lines(original.fields and original.fields.description), "\n")
    ),
    original_epic = original_epic,
    custom_field_defs = definitions,
    original_custom_fields = original_custom_fields,
    custom_field_read_errors = read_errors,
    layout = {
      label_width = label_width,
      anchors = {},
    },
  }

  -- Seed stable field anchors in a dedicated namespace that is never cleared
  -- by visual decoration refreshes.
  vim.api.nvim_buf_clear_namespace(buf, M.ns_anchor, 0, -1)
  local anchors = M.cache[buf].layout.anchors
  local extmark_opts = { right_gravity = false }
  
  if vim.fn.has("nvim-0.10") == 1 then
     extmark_opts.strict = false
  end

  anchors.project = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 0, 0, extmark_opts)
  anchors.epic = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 1, 0, extmark_opts)
  anchors.type = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 2, 0, extmark_opts)
  anchors.components = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 3, 0, extmark_opts)
  anchors.labels = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 4, 0, extmark_opts)
  anchors.status = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 5, 0, extmark_opts)
  anchors.assignee = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, 6, 0, extmark_opts)
  for name, row in pairs(field_rows) do
    anchors[name] = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, row, 0, extmark_opts)
  end
  anchors.divider1 = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, divider_row, 0, extmark_opts)
  anchors.summary = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, divider_row + 1, 0, extmark_opts)
  anchors.divider2 = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, divider_row + 2, 0, extmark_opts)
  anchors.description = vim.api.nvim_buf_set_extmark(buf, M.ns_anchor, divider_row + 3, 0, extmark_opts)

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
    cli.get_issue(key, function(fetched)
      if fetched then
        -- Overrides only affect what is shown; the diff baseline stays the
        -- issue as fetched so restored drafts still register as changes.
        local issue = vim.deepcopy(fetched)
        apply_row_overrides(issue, pending and pending.row_fields or nil)
        apply_parsed_overrides(issue, draft)
        render_issue(buf, key, issue, false, { original = vim.deepcopy(fetched), draft = draft })
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
    parsed.fields.labels = get_value("Labels")
    parsed.fields.status = get_value("Status")
    parsed.fields.assignee = get_value("Assignee")
    parsed.summary = get_value("Summary")
    parsed.custom_fields = {}
    parsed.custom_field_defs = vim.deepcopy(data.custom_field_defs or {})
    for i, field in ipairs(parsed.custom_field_defs) do
      local row = get_field_row(buf, "custom:" .. field.id)
      local next_field = parsed.custom_field_defs[i + 1]
      local last = get_field_row(buf, next_field and ("custom:" .. next_field.id) or "divider1")
      if row and last and last > row then
        parsed.custom_fields[field.id] = table.concat(vim.api.nvim_buf_get_lines(buf, row - 1, last - 1, false), "\n")
      end
    end

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
  local orig_description = data.original_description
  if not orig_description then
    local raw = orig.fields and orig.fields.description or ""
    if type(raw) == "table" then
      raw = table.concat(extract_adf_text(raw))
    end
    orig_description = normalize_description(raw)
  end
  changes.description_changed = normalize_description(parsed.description) ~= orig_description
  changes.new_description = parsed.description

  -- Assignee
  local orig_assignee = ""
  if orig.fields and orig.fields.assignee and type(orig.fields.assignee) == "table" then
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
  local orig_epic_key = extract_epic_key(data.original_epic)
  changes.epic_changed = new_epic_key ~= orig_epic_key
  changes.new_epic_key = new_epic_key
  changes.orig_epic_key = orig_epic_key

  -- Components
  local orig_components_str = components_text(orig.fields or {})
  local new_components_str = util.labels_to_string(parsed.fields.components)
  changes.components_changed = new_components_str ~= orig_components_str
  changes.orig_components = orig_components_str
  changes.new_components = new_components_str

  -- Type
  local orig_type = config.options.defaults.issue_type
  if orig.fields then
    local itype = orig.fields.issuetype or orig.fields.issueType
    if itype then orig_type = itype.name or "" end
  end
  local new_type = parsed.fields.type or ""
  changes.type_changed = new_type ~= orig_type
  changes.new_type = new_type

  -- Labels
  local orig_labels_str = util.labels_to_string(orig.fields and orig.fields.labels or "")
  local new_labels_str = util.labels_to_string(parsed.fields.labels or "")
  changes.labels_changed = new_labels_str ~= orig_labels_str
  changes.orig_labels = orig_labels_str
  changes.new_labels = new_labels_str

  changes.custom_field_updates, changes.custom_field_errors = custom.diff(
    data.custom_field_defs, parsed.custom_fields, data.original_custom_fields, data.custom_field_read_errors, data.is_new
  )
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
    or diff.labels_changed
    or #(diff.custom_field_updates or {}) > 0
    or #(diff.custom_field_errors or {}) > 0
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
  if not key or key == "" then return false end
  local draft = M.drafts[key]
  if not draft then return false end
  if draft.diff and draft.diff.queued_for_removal then return true end
  return has_any_changes(draft.diff)
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
  local old_draft = M.drafts[data.key]
  if old_draft and old_draft.diff and old_draft.diff.queued_for_removal then
    diff.queued_for_removal = true
  end

  if has_any_changes(diff) or diff.queued_for_removal then
    M.drafts[data.key] = {
      buf = buf,
      parsed = parsed,
      diff = diff,
    }
  else
    M.drafts[data.key] = nil
  end
  refresh_winbar_for_key(data.key)
  refresh_list_draft_markers(data.key)
  return diff
end

local function reconcile_draft(buf)
  local diff = M.capture_draft(buf)
  if diff then vim.bo[buf].modified = has_any_changes(diff) end
end

---Record custom fields that reached Jira, retaining any newer edits for retry.
function M.commit_custom_fields(key, updates)
  local draft = M.drafts[key]
  if draft and draft.diff then
    local pending = {}
    for _, update in ipairs(draft.diff.custom_field_updates or {}) do
      local applied = false
      for _, saved in ipairs(updates) do
        if saved.field.id == update.field.id then
          if saved.value == update.value then applied = true else update.previous = saved.value end
          break
        end
      end
      if not applied then table.insert(pending, update) end
    end
    draft.diff.custom_field_updates = pending
  end
  for buf, data in pairs(M.cache) do
    if data.key == key and not data.is_new then
      data.original.fields = data.original.fields or {}
      custom.apply(data.original.fields, updates)
      data.original_custom_fields = data.original_custom_fields or {}
      for _, update in ipairs(updates) do data.original_custom_fields[update.field.id] = update.value end
      if vim.api.nvim_buf_is_loaded(buf) then reconcile_draft(buf) end
    end
  end
end

---Advance only the fields Jira accepted, including when the editor is closed.
function M.commit_fields(key, saved, opts)
  opts = opts or {}
  local draft = M.drafts[key]
  if draft then
    local diff = draft.diff
    if opts.close then
      diff.queued_for_removal = nil
      if diff.new_status == opts.draft_status then diff.status_changed = false end
    end
    for field, value in pairs(saved) do
      local changed = field .. "_changed"
      if diff[changed] then
        if field == "epic" then
          diff.orig_epic_key = extract_epic_key(value)
          diff[changed] = diff.new_epic_key ~= diff.orig_epic_key
        elseif field == "description" then
          diff[changed] = normalize_description(diff.new_description) ~= normalize_description(value)
        else
          diff[changed] = diff["new_" .. field] ~= value
          if field == "labels" or field == "components" then diff["orig_" .. field] = value end
        end
      end
    end
    if not has_any_changes(diff) and not diff.queued_for_removal then
      M.clear_draft(key)
    end
  end
  for buf, data in pairs(M.cache) do
    if data.key == key and not data.is_new and vim.api.nvim_buf_is_loaded(buf) then
      local diff = opts.from_list and compute_issue_diff(data, M.parse_buffer(buf))
      local fields = data.original.fields
      for field, value in pairs(saved) do
        if field == "epic" then
          data.original_epic = value
        elseif field == "description" then
          fields.description = value
          data.original_description = normalize_description(value)
        elseif field == "assignee" then
          fields.assignee = value ~= "Unassigned" and { displayName = value } or nil
        elseif field == "status" then
          fields.status = { name = value }
        elseif field == "labels" then
          fields.labels = util.labels_to_list(value)
        elseif field == "components" then
          fields.components = {}
          for _, name in ipairs(util.labels_to_list(value)) do
            table.insert(fields.components, { name = name })
          end
        else
          fields[field] = value
        end
        -- List edits can change a field whose issue editor still shows the old
        -- value. Refresh that field while keeping any newer text typed there.
        local confirmed_close = diff and opts.close and field == "status" and diff.new_status == opts.draft_status
        local submitted_from_here = opts.draft_buf == buf and opts.draft_fields[field]
        if diff and (confirmed_close or not (diff[field .. "_changed"] or submitted_from_here)) then
          if field == "description" then
            local row = get_field_row(buf, "Description")
            if row then
              vim.api.nvim_buf_set_lines(buf, row - 1, -1, false, description_lines(value))
            end
          else
            update_field(buf, field, value)
          end
        end
      end
      reconcile_draft(buf)
    end
  end
end

function M.edit_error(key, type_changed, description)
  if type_changed then
    return "Change the issue type for " .. key .. " in Jira, then refresh its editor. jira-cli supports type selection on creation."
  end
  if description ~= nil and normalize_description(description) == "" then
    return "Clear the description for " .. key .. " in Jira, then refresh its editor."
  end
end

---Execute a sequence of async steps, calling done_cb when all complete
---@param steps table[] Array of { fn = function(next_cb) }
---@param done_cb function(has_errors: boolean)
local function exec_steps(steps, done_cb)
  local idx = 0

  local function run_next()
    idx = idx + 1
    if idx > #steps then
      done_cb(false)
      return
    end
    steps[idx].fn(function(err)
      if err then done_cb(true); return end
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
  if data.saving then
    vim.notify("A Jira save is already in progress for this issue.", vim.log.levels.WARN)
    return
  end
  if data.create_without_key then
    vim.notify("This issue was created but its key could not be read. Find its key in Jira and reopen it before saving again.", vim.log.levels.ERROR)
    return
  end

  local parsed = M.parse_buffer(buf)
  local saved_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diff = compute_issue_diff(data, parsed)
  if not data.is_new then M.capture_draft(buf) end
  if #diff.custom_field_errors > 0 then
    vim.notify(table.concat(diff.custom_field_errors, "\n"), vim.log.levels.ERROR)
    vim.bo[buf].modified = true
    return
  end

  if parsed.summary == "" then
    vim.notify("Summary cannot be empty.", vim.log.levels.ERROR)
    return
  end

  if not data.is_new then
    local err = M.edit_error(data.key, diff.type_changed, diff.description_changed and diff.new_description or nil)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
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

    if parsed.fields.labels and parsed.fields.labels ~= "" then
      for lbl in string.gmatch(parsed.fields.labels, "[^,]+") do
        lbl = vim.trim(lbl)
        if lbl ~= "" then
          table.insert(args, "--label")
          table.insert(args, lbl)
        end
      end
    end

    if parsed.description and parsed.description ~= "" then
      table.insert(args, "--body")
      table.insert(args, parsed.description)
    end

    custom.append_args(args, diff.custom_field_updates, true)
    data.saving = true
    cli.exec(args, function(stdout, stderr, code)
      if code ~= 0 then
        data.saving = nil
        vim.notify("Failed to create issue: " .. (stderr or ""), vim.log.levels.ERROR)
        if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = true end
        return
      end
      local created_key = util.extract_issue_key((stdout or "") .. "\n" .. (stderr or ""))
      if not created_key then
        data.saving = nil
        data.create_without_key = true
        cli.clear_cache("all")
        vim.notify("Issue created but its key could not be read. Find its key in Jira and reopen it before saving again.", vim.log.levels.ERROR)
        if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = true end
        return
      end
      data.key, data.is_new = created_key, false
      data.original_epic = parsed.fields.epic
      data.original = data.original or { fields = {} }
      data.original.fields = data.original.fields or {}
      local fields = data.original.fields
      custom.apply(fields, diff.custom_field_updates)
      for _, update in ipairs(diff.custom_field_updates) do data.original_custom_fields[update.field.id] = update.value end
      fields.summary, fields.description = parsed.summary, parsed.description
      data.original_description = normalize_description(parsed.description)
      if parsed.fields.assignee and parsed.fields.assignee ~= "" and parsed.fields.assignee ~= "Unassigned" then
        fields.assignee = { displayName = parsed.fields.assignee }
      else
        fields.assignee = nil
      end
      fields.status = { name = config.options.defaults.status }
      if parsed.fields.type and parsed.fields.type ~= "" then fields.issuetype = { name = parsed.fields.type } end
      fields.components = {}
      for comp in string.gmatch(parsed.fields.components or "", "[^,]+") do
        comp = vim.trim(comp)
        if comp ~= "" then table.insert(fields.components, { name = comp }) end
      end
      fields.labels = util.labels_to_list(parsed.fields.labels)
      if parsed.fields.project and parsed.fields.project ~= "" then fields.project = { key = parsed.fields.project } end
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_set_name(buf, "jira-oil://issue/" .. created_key) end
      local function complete(failed)
        data.saving = nil
        cli.clear_cache("all")
        if not failed then vim.notify("Issue created successfully: " .. created_key, vim.log.levels.INFO) end
        if vim.api.nvim_buf_is_valid(buf) then
          M.capture_draft(buf)
          vim.bo[buf].modified = failed or not vim.deep_equal(saved_lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        end
      end
      local status = parsed.fields.status or ""
      if status ~= "" and status ~= fields.status.name then
        cli.exec({ "issue", "move", created_key, status }, function(_, move_err, move_code)
          if move_code ~= 0 then
            vim.notify("Issue created, but its status update failed: " .. (move_err or ""), vim.log.levels.ERROR)
            complete(true)
          else
            fields.status = { name = status }
            complete(false)
          end
        end)
      else
        complete(false)
      end
    end)
  else
    local key, steps = data.key, {}
    local function add_step(args, saved, field, custom_updates)
      table.insert(steps, { fn = function(next_cb)
        cli.exec(args, function(_, stderr, code)
          if code == 0 then
            if next(saved) then M.commit_fields(key, saved) end
            if custom_updates and #custom_updates > 0 then M.commit_custom_fields(key, custom_updates) end
          else
            vim.notify("Failed to update " .. field .. " for " .. key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
          end
          next_cb(code ~= 0)
        end)
      end })
    end

    if diff.summary_changed or diff.description_changed or #diff.custom_field_updates > 0 then
      local args = { "issue", "edit", key, "--no-input" }
      local saved = {}
      if diff.summary_changed then
        vim.list_extend(args, { "-s", diff.new_summary })
        saved.summary = diff.new_summary
      end
      if diff.description_changed then
        vim.list_extend(args, { "--body", diff.new_description })
        saved.description = diff.new_description
      end
      custom.append_args(args, diff.custom_field_updates, false)
      add_step(args, saved, "issue fields", diff.custom_field_updates)
    end
    if diff.assignee_changed then
      local input = diff.new_assignee
      local assignee = input == "Unassigned" and "x"
        or util.resolve_assignee_for_cli(input, nil)
        or util.resolve_assignee_for_cli(input, data.original.fields.assignee)
        or input
      local args = { "issue", "assign", key, assignee }
      local project = util.issue_project_from_key(key)
      if project then vim.list_extend(args, { "--project", project }) end
      add_step(args, { assignee = input }, "assignee")
    end
    if diff.status_changed then
      add_step({ "issue", "move", key, diff.new_status }, { status = diff.new_status }, "status")
    end
    if diff.epic_changed then
      table.insert(steps, { fn = function(next_cb)
        cli.set_issue_epic(key, diff.new_epic_key, function(ok)
          if ok then M.commit_fields(key, { epic = parsed.fields.epic }) end
          next_cb(not ok)
        end)
      end })
    end
    for _, field in ipairs({ "components", "labels" }) do
      if diff[field .. "_changed"] then
        local flag = field == "components" and "--component" or "--label"
        local desired = diff["new_" .. field]
        local args = { "issue", "edit", key, "--no-input" }
        cli.append_list_delta(args, flag, diff["orig_" .. field], desired)
        if #args > 4 then add_step(args, { [field] = desired }, field) end
      end
    end

    if #steps == 0 then
      vim.notify("No changes to apply.", vim.log.levels.INFO)
      vim.bo[buf].modified = false
      return
    end

    local release = M.reserve_updates({ key })
    if not release then return end
    data.saving = true
    exec_steps(steps, function(has_errors)
      data.saving = nil
      release()
      cli.clear_cache("all")
      if has_errors then
        vim.notify("Some updates failed for " .. key .. ". Check messages above.", vim.log.levels.WARN)
      else
        vim.notify("Issue " .. key .. " updated successfully!", vim.log.levels.INFO)
      end
      if vim.api.nvim_buf_is_loaded(buf) and M.cache[buf] == data then
        reconcile_draft(buf)
      end
    end)
  end
end

function M.reset(buf)
  local data = M.cache[buf]
  if not data then return end
  if data.saving then
    vim.notify("Wait for the Jira save to finish before resetting the issue editor.", vim.log.levels.WARN)
    return
  end
  if not data.is_new and data.key and data.key ~= "" then
    M.clear_draft(data.key)
  end
  local issue = data.original or { fields = {} }
  if data.create_without_key then
    vim.notify("Find the created issue key in Jira and reopen it before resetting.", vim.log.levels.ERROR)
    return
  end
  render_issue(buf, data.key, issue, data.is_new, { original_epic = data.original_epic })
end

function M.discard_draft(key)
  local had_draft = M.has_draft(key)
  M.clear_draft(key)
  for buf, data in pairs(M.cache) do
    if data.key == key and not data.is_new and vim.api.nvim_buf_is_loaded(buf) and (had_draft or vim.bo[buf].modified) then
      M.reset(buf)
    end
  end
end

function M.pick_epic(buf)
  pick_epic(buf)
end

function M.pick_components(buf)
  pick_components(buf)
end

return M
