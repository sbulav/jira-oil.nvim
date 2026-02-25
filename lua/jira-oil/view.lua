local cli = require("jira-oil.cli")
local parser = require("jira-oil.parser")
local config = require("jira-oil.config")
local actions = require("jira-oil.actions")
local util = require("jira-oil.util")

local M = {}

M.cache = {}
M.open_seq = {}

--- Sentinel lines written into the buffer for section headers.
--- The mutator treats any line matching one of these as a non-issue boundary.
M.header_sprint  = "----- sprint -----"
M.header_backlog = "----- backlog -----"
--- Legacy alias – the mutator used to check for M.separator.
M.separator = M.header_backlog

--- Namespace for highlights, header overlays, and general extmarks.
M.ns = vim.api.nvim_create_namespace("JiraOilList")

--- Dedicated namespace for inline virtual-text key extmarks so they can
--- be queried independently without iterating all extmarks.
M.ns_keys = vim.api.nvim_create_namespace("JiraOilKeys")
M.ns_copy = vim.api.nvim_create_namespace("JiraOilCopiedSource")
M.ns_draft = vim.api.nvim_create_namespace("JiraOilDraftMarker")

M.last_yank = nil

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

local function define_highlights()
  local hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  -- Column highlights
  hl("JiraOilKey",       { link = "Identifier" })
  hl("JiraOilStatus",    { link = "DiagnosticInfo" })
  hl("JiraOilAssignee",  { link = "Comment" })
  hl("JiraOilSummary",   { link = "Normal" })
  hl("JiraOilSeparator", { link = "Comment" })

  -- Status-specific
  hl("JiraOilStatusOpen",       { link = "DiagnosticHint" })
  hl("JiraOilStatusInProgress", { link = "DiagnosticWarn" })
  hl("JiraOilStatusInReview",   { link = "DiagnosticInfo" })
  hl("JiraOilStatusDone",       { link = "DiagnosticOk" })
  hl("JiraOilStatusBlocked",    { link = "DiagnosticError" })

  -- Section headers
  hl("JiraOilSectionRule",  { link = "WinSeparator" })
  hl("JiraOilSectionLabel", { link = "Title" })
  hl("JiraOilSectionCount", { link = "Comment" })
  hl("JiraOilDraft", { link = "Comment" })

  -- Winbar
  hl("JiraOilWinbar",        { link = "WinBar" })
  hl("JiraOilWinbarProject", { link = "Title" })
  hl("JiraOilWinbarSep",     { link = "WinSeparator" })
  hl("JiraOilWinbarCount",   { link = "Comment" })
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("JiraOilHighlights", { clear = true }),
  callback = define_highlights,
})

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Is this line a section header sentinel?
---@param line string
---@return boolean
local function is_header(line)
  return line == M.header_sprint or line == M.header_backlog
end

---@param project string|nil
---@return string
local function newtask_placeholder(project)
  local p = util.trim(project or "")
  if p == "" then
    p = "PROJECT"
  end
  return p .. "-NEWTASK"
end

--- Build a column-aligned section header overlay.
--- The output accounts for the key virtual-text width so headers line up
--- with data rows (which have inline virt_text shifting them right).
---@param label string  e.g. "Sprint", "Backlog"
---@param count number|nil
---@return table[] chunks  for virt_text overlay
local function build_header_chunks(label, count)
  local columns = config.options.view.columns
  local key_width = config.options.view.key_width or 12
  local sections = config.options.view.sections or {}
  local show_count = sections.show_count ~= false

  local chunks = {}

  -- Section label occupies the key-column area
  local section_text = label
  if show_count and count then
    section_text = section_text .. " (" .. count .. ")"
  end
  table.insert(chunks, { util.pad_right(section_text, key_width) .. " ", "JiraOilSectionLabel" })

  -- Column names aligned to the editable column widths
  local sep = " \u{2502} "
  for i, col in ipairs(columns) do
    if i > 1 then
      table.insert(chunks, { sep, "JiraOilSectionRule" })
    end
    local header = col.name:upper()
    if col.width then
      header = util.pad_right(header, col.width)
    end
    table.insert(chunks, { header, "JiraOilSectionRule" })
  end

  return chunks
end

--- Apply all decorations to a rendered buffer: column highlights, key
--- virtual text, header overlays, and winbar.
---@param buf number
---@param lines string[]           buffer text lines
---@param issue_keys (string|nil)[] parallel array: issue key per line, nil for non-issue lines
---@param sprint_count number
---@param backlog_count number
---@param target string
---@param draft_keys table<string, boolean>|nil
local function apply_decorations(buf, lines, issue_keys, sprint_count, backlog_count, target, draft_keys)
  local scratch = require("jira-oil.scratch")

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_keys, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_draft, 0, -1)

  local columns = config.options.view.columns
  local col_hl = config.options.view.column_highlights or {}
  local status_hl = config.options.view.status_highlights or {}
  local key_width = config.options.view.key_width or 12
  local sections_cfg = config.options.view.sections or {}

  local sep = " \u{2502} "
  local sep_byte_len = #sep

  for lnum, line in ipairs(lines) do
    local row = lnum - 1 -- 0-indexed

    if is_header(line) then
      -- Section header overlay – column-aligned with a label in the key area
      local label, count
      if line == M.header_sprint then
        label = sections_cfg.sprint_label or "Sprint"
        count = sprint_count
      else
        label = sections_cfg.backlog_label or "Backlog"
        count = backlog_count
      end
      local chunks = build_header_chunks(label, count)
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        virt_text = chunks,
        virt_text_pos = "overlay",
      })
    else
      -- Key virtual text (inline, read-only)
      local key = issue_keys[lnum]
      if key then
        local padded = util.pad_right(key, key_width) .. " "
        vim.api.nvim_buf_set_extmark(buf, M.ns_keys, row, 0, {
          virt_text = { { padded, "JiraOilKey" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })

        if (draft_keys and draft_keys[key]) or scratch.has_draft(key) then
          vim.api.nvim_buf_set_extmark(buf, M.ns_draft, row, 0, {
            virt_text = { { " [draft]", "JiraOilDraft" } },
            virt_text_pos = "eol",
          })
        end
      else
        -- New issue line placeholder keeps alignment and marks create intent.
        local source_key = M.get_copy_source_at_line(buf, row)
        local source_project = util.issue_project_from_key(source_key)
        local project = source_project or config.options.defaults.project
        local placeholder = newtask_placeholder(project)
        local padded = util.pad_right(placeholder, key_width) .. " "
        vim.api.nvim_buf_set_extmark(buf, M.ns_keys, row, 0, {
          virt_text = { { padded, "JiraOilKey" } },
          virt_text_pos = "inline",
          right_gravity = false,
        })
      end

      -- Column highlights on the inline buffer text
      local parts = vim.split(line, sep, { plain = true })
      local start_col = 0
      for idx, col in ipairs(columns) do
        local part = parts[idx] or ""
        local byte_width = #part
        local hl_group = col_hl[col.name] or "Normal"
        if col.name == "status" then
          local status = util.strip_icon(util.trim(part))
          if status ~= "" and status_hl[status] then
            hl_group = status_hl[status]
          end
        end
        if byte_width > 0 then
          vim.api.nvim_buf_set_extmark(buf, M.ns, row, start_col, {
            end_col = start_col + byte_width,
            hl_group = hl_group,
          })
        end
        start_col = start_col + byte_width + sep_byte_len
      end
    end
  end

  -- Winbar
  if config.options.view.show_winbar ~= false then
    local project = config.options.defaults.project
    local total = sprint_count + backlog_count
    local target_label = target
    if target == "all" then
      target_label = "Sprint + Backlog"
    elseif target == "sprint" then
      target_label = "Sprint"
    elseif target == "backlog" then
      target_label = "Backlog"
    end
    local columns = config.options.view.columns
    local count_text = total .. " issue" .. (total == 1 and "" or "s")

    local function gutter_width(win)
      local width = 0
      local wo = vim.wo[win]

      -- Number/relative number column
      if wo.number or wo.relativenumber then
        width = width + wo.numberwidth
      end

      -- Sign column (typically 2 cells when enabled)
      local sc = wo.signcolumn
      if sc ~= "no" then
        local n = sc:match("yes:(%d+)") or sc:match("auto:(%d+)")
        if n then
          width = width + tonumber(n)
        elseif sc == "yes" or sc == "auto" or sc == "number" then
          width = width + 2
        end
      end

      -- Fold column
      local fc = wo.foldcolumn
      local fcn = tostring(fc):match("(%d+)")
      if fcn then
        width = width + tonumber(fcn)
      end

      return width
    end

    local sep_txt = " \u{2502} "
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      local pad = string.rep(" ", gutter_width(win))

      -- Build a column-aligned winbar so values sit above list columns:
      -- key area -> project, first editable col -> section, last col -> count.
      local wb = "%#JiraOilWinbar#" .. pad .. "%*"

      local project_text = project ~= "" and project or "JIRA"
      wb = wb .. "%#JiraOilWinbarProject#" .. util.pad_right(project_text, key_width) .. " %*"

      local parts = {}
      for i, col in ipairs(columns) do
        local v = ""
        if i == 1 then
          v = target_label
        elseif i == #columns then
          v = count_text
        end
        if col.width then
          v = util.pad_right(v, col.width)
        end
        parts[i] = v
      end

      for i, part in ipairs(parts) do
        if i > 1 then
          wb = wb .. "%#JiraOilWinbarSep#" .. sep_txt .. "%*"
        end
        local hl = (i == #parts) and "JiraOilWinbarCount" or "JiraOilWinbar"
        wb = wb .. "%#" .. hl .. "#" .. part .. "%*"
      end

      vim.wo[win].winbar = wb
    end
  end
end

---@param issue_keys (string|nil)[]
---@return table<string, number[]>
local function build_rows_by_key(issue_keys)
  local rows_by_key = {}
  for i, key in ipairs(issue_keys or {}) do
    if key and key ~= "" then
      local row = i - 1
      if not rows_by_key[key] then
        rows_by_key[key] = {}
      end
      table.insert(rows_by_key[key], row)
    end
  end
  return rows_by_key
end

---@param item table
---@return string
local function format_structured_item(item)
  local issue = {
    key = item.key,
    fields = {
      status = { name = item.status or "" },
      summary = item.summary or "",
      issuetype = { name = item.type or "" },
    },
  }
  if item.assignee and item.assignee ~= "" and item.assignee ~= "Unassigned" then
    issue.fields.assignee = { displayName = item.assignee }
  end
  return parser.format_line(issue)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Resolve the issue key for a given 0-indexed row by reading key extmarks.
---@param buf number
---@param row number 0-indexed line number
---@return string|nil key
function M.get_key_at_line(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_keys, { row, 0 }, { row, 0 }, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    local vt = details.virt_text
    if vt and vt[1] and vt[1][1] then
      local key = util.trim(vt[1][1])
      if key ~= "" and not util.is_newtask_key(key) then
        return key
      end
    end
  end
  return nil
end

---Build a full mapping of 0-indexed row -> issue key by reading all key
---extmarks.  Used by the mutator to resolve identity for every line.
---@param buf number
---@return table<number, string> row_to_key
function M.get_all_line_keys(buf)
  local row_to_key = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_keys, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    local vt = details.virt_text
    if vt and vt[1] and vt[1][1] then
      local key = util.trim(vt[1][1])
      if key ~= "" and not util.is_newtask_key(key) then
        row_to_key[mark[2]] = key  -- mark[2] is the 0-indexed row
      end
    end
  end
  return row_to_key
end

---@param buf number
---@param row number
---@param source_key string
function M.set_copy_source_at_line(buf, row, source_key)
  local data = M.cache[buf]
  if not data then
    return
  end
  data.copy_sources = data.copy_sources or {}
  local id = vim.api.nvim_buf_set_extmark(buf, M.ns_copy, row, 0, {
    right_gravity = false,
  })
  data.copy_sources[id] = source_key
end

---@param buf number
---@param row number
function M.clear_copy_source_at_line(buf, row)
  local data = M.cache[buf]
  if not data or not data.copy_sources then
    return
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_copy, { row, 0 }, { row, 0 }, {})
  for _, mark in ipairs(marks) do
    data.copy_sources[mark[1]] = nil
    vim.api.nvim_buf_del_extmark(buf, M.ns_copy, mark[1])
  end
end

---@param buf number
---@param row number
---@return string|nil
function M.get_copy_source_at_line(buf, row)
  local data = M.cache[buf]
  if not data or not data.copy_sources then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_copy, { row, 0 }, { row, 0 }, { limit = 1 })
  if #marks == 0 then
    return nil
  end
  return data.copy_sources[marks[1][1]]
end

---@param buf number
---@return table<number, string>
function M.get_all_copy_sources(buf)
  local out = {}
  local data = M.cache[buf]
  if not data or not data.copy_sources then
    return out
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_copy, 0, -1, {})
  for _, mark in ipairs(marks) do
    local source_key = data.copy_sources[mark[1]]
    if source_key and source_key ~= "" then
      out[mark[2]] = source_key
    end
  end
  return out
end

---@param buf number
---@param row number
---@param key string
function M.set_line_key(buf, row, key)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_keys, row, row + 1)
  local key_width = config.options.view.key_width or 12
  local padded = util.pad_right(key, key_width) .. " "
  vim.api.nvim_buf_set_extmark(buf, M.ns_keys, row, 0, {
    virt_text = { { padded, "JiraOilKey" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

---@param buf number
---@param row_to_key table<number, string>
function M.replace_all_line_keys(buf, row_to_key)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_keys, 0, -1)
  for row, key in pairs(row_to_key or {}) do
    if key and key ~= "" then
      local key_width = config.options.view.key_width or 12
      local padded = util.pad_right(key, key_width) .. " "
      vim.api.nvim_buf_set_extmark(buf, M.ns_keys, row, 0, {
        virt_text = { { padded, "JiraOilKey" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
    end
  end
end

---@param buf number
---@param row_to_source table<number, string>
function M.replace_all_copy_sources(buf, row_to_source)
  local data = M.cache[buf]
  if not data then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns_copy, 0, -1)
  data.copy_sources = {}
  for row, source_key in pairs(row_to_source or {}) do
    if source_key and source_key ~= "" then
      local id = vim.api.nvim_buf_set_extmark(buf, M.ns_copy, row, 0, {
        right_gravity = false,
      })
      data.copy_sources[id] = source_key
    end
  end
end

---@param buf number
function M.decorate_current(buf)
  local data = M.cache[buf]
  if not data or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local scratch = require("jira-oil.scratch")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row_to_key = M.get_all_line_keys(buf)
  local issue_keys = {}
  local draft_keys = {}
  local original_by_key = {}
  for _, item in ipairs(data.original or {}) do
    if item and item.key and item.key ~= "" then
      original_by_key[item.key] = item
    end
  end

  local sprint_count, backlog_count = 0, 0
  local in_backlog = data.target == "backlog"

  for i, line in ipairs(lines) do
    local row = i - 1
    if line == M.header_backlog then
      in_backlog = true
    elseif line == M.header_sprint then
      in_backlog = false
    else
      local key = row_to_key[row]
      issue_keys[i] = key
      if line:match("%S") then
        if key and key ~= "" then
          if scratch.has_draft(key) then
            draft_keys[key] = true
          else
            local parsed = parser.parse_line(line)
            local orig = original_by_key[key]
            if (not parsed) or (not orig) then
              draft_keys[key] = true
            else
              local current_section = in_backlog and "backlog" or "sprint"
              local changed = false
              if current_section ~= (orig.section or current_section) then
                changed = true
              end
              if parsed.status ~= nil and parsed.status ~= (orig.status or "") then
                changed = true
              end
              if parsed.assignee ~= nil and parsed.assignee ~= (orig.assignee or "") then
                changed = true
              end
              if parsed.summary ~= nil and parsed.summary ~= (orig.summary or "") then
                changed = true
              end
              if parsed.type ~= nil and parsed.type ~= (orig.type or "") then
                changed = true
              end
              if changed then
                draft_keys[key] = true
              end
            end
          end
        end
        if in_backlog then
          backlog_count = backlog_count + 1
        else
          sprint_count = sprint_count + 1
        end
      end
    end
  end

  apply_decorations(buf, lines, issue_keys, sprint_count, backlog_count, data.target, draft_keys)
  data.rows_by_key = build_rows_by_key(issue_keys)
end

---@param buf number
---@param uri string
function M.open(buf, uri)
  local target = uri:match("^jira%-oil://(.*)$")
  if not target or (target ~= "sprint" and target ~= "backlog" and target ~= "all") then
    vim.notify("Invalid URI: " .. uri, vim.log.levels.ERROR)
    return
  end

  M.open_seq[buf] = (M.open_seq[buf] or 0) + 1
  local seq = M.open_seq[buf]

  local function is_stale_request()
    return (M.open_seq[buf] ~= seq) or (not vim.api.nvim_buf_is_valid(buf))
  end

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "jira-oil"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.b[buf].jira_oil_kind = "list"

  -- Disable undo while loading
  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading " .. target .. "..." })

  --- Build buffer lines and parallel metadata from a list of issues.
  ---@param issues table[]
  ---@param section string
  ---@param lines string[]
  ---@param issue_keys (string|nil)[]
  ---@param structured table[]
  local function render_section(issues, section, lines, issue_keys, structured)
    for _, issue in ipairs(issues) do
      local line = parser.format_line(issue)
      table.insert(lines, line)
      issue_keys[#lines] = issue.key or nil
      local parsed = parser.parse_line(line)
      if parsed then
        parsed.key = issue.key or ""
        parsed.section = section
        table.insert(structured, parsed)
      end
    end
  end

  local function finish(lines, issue_keys, structured, sprint_count, backlog_count)
    if is_stale_request() then return end

    M.cache[buf] = {
      uri = uri,
      target = target,
      original = structured,
      rows_by_key = build_rows_by_key(issue_keys),
      copy_sources = {},
    }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].undolevels = old_undolevels

    apply_decorations(buf, lines, issue_keys, sprint_count, backlog_count, target, nil)
    actions.setup(buf)
  end

  if target == "all" then
    cli.get_sprint_issues(function(sprint_issues)
      if is_stale_request() then
        return
      end
      cli.get_backlog_issues(function(backlog_issues)
        if is_stale_request() then
          return
        end
        local lines = {}
        local issue_keys = {}
        local structured = {}

        -- Sprint header
        table.insert(lines, M.header_sprint)
        issue_keys[#lines] = nil

        render_section(sprint_issues, "sprint", lines, issue_keys, structured)

        -- Backlog header
        table.insert(lines, M.header_backlog)
        issue_keys[#lines] = nil

        render_section(backlog_issues, "backlog", lines, issue_keys, structured)

        finish(lines, issue_keys, structured, #sprint_issues, #backlog_issues)
      end)
    end)
  else
    local fetcher = target == "sprint" and cli.get_sprint_issues or cli.get_backlog_issues
    fetcher(function(issues)
      if is_stale_request() then
        return
      end
      local lines = {}
      local issue_keys = {}
      local structured = {}

      -- Single-section header
      local hdr = target == "sprint" and M.header_sprint or M.header_backlog
      table.insert(lines, hdr)
      issue_keys[#lines] = nil

      render_section(issues, target, lines, issue_keys, structured)

      local sc = target == "sprint" and #issues or 0
      local bc = target == "backlog" and #issues or 0
      finish(lines, issue_keys, structured, sc, bc)
    end)
  end
end

function M.refresh(buf)
  local data = M.cache[buf]
  if data then
    cli.clear_cache("all")
    M.open(buf, data.uri)
  end
end

function M.reset(buf)
  local data = M.cache[buf]
  if not data or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = {}
  local issue_keys = {}
  data.copy_sources = {}
  vim.api.nvim_buf_clear_namespace(buf, M.ns_copy, 0, -1)

  local function add_header(header)
    table.insert(lines, header)
    issue_keys[#lines] = nil
  end

  local function add_item(item)
    local line = format_structured_item(item)
    table.insert(lines, line)
    issue_keys[#lines] = item.key or nil
  end

  if data.target == "all" then
    add_header(M.header_sprint)
    for _, item in ipairs(data.original or {}) do
      if item.section == "sprint" then
        add_item(item)
      end
    end
    add_header(M.header_backlog)
    for _, item in ipairs(data.original or {}) do
      if item.section == "backlog" then
        add_item(item)
      end
    end
  else
    local section = data.target
    local header = section == "sprint" and M.header_sprint or M.header_backlog
    add_header(header)
    for _, item in ipairs(data.original or {}) do
      if (item.section or section) == section then
        add_item(item)
      end
    end
  end

  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = old_undolevels

  -- Recount sections for the header overlays
  local sprint_count, backlog_count = 0, 0
  local in_backlog = false
  for i, line in ipairs(lines) do
    if line == M.header_backlog then
      in_backlog = true
    elseif not is_header(line) and issue_keys[i] then
      if in_backlog then
        backlog_count = backlog_count + 1
      else
        sprint_count = sprint_count + 1
      end
    end
  end

  apply_decorations(buf, lines, issue_keys, sprint_count, backlog_count, data.target, nil)
  data.rows_by_key = build_rows_by_key(issue_keys)
end

---@param key string
function M.update_draft_marker_for_key(key)
  if not key or key == "" then
    return
  end
  local scratch = require("jira-oil.scratch")
  local has_draft = scratch.has_draft(key)

  for buf, data in pairs(M.cache) do
    if data and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].jira_oil_kind == "list" then
      local rows = data.rows_by_key and data.rows_by_key[key]
      if rows and #rows > 0 then
        for _, row in ipairs(rows) do
          vim.api.nvim_buf_clear_namespace(buf, M.ns_draft, row, row + 1)
          if has_draft then
            vim.api.nvim_buf_set_extmark(buf, M.ns_draft, row, 0, {
              virt_text = { { " [draft]", "JiraOilDraft" } },
              virt_text_pos = "eol",
            })
          end
        end
      end
    end
  end
end

return M
