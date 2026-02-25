local cli = require("jira-oil.cli")
local parser = require("jira-oil.parser")
local config = require("jira-oil.config")
local actions = require("jira-oil.actions")
local util = require("jira-oil.util")

local M = {}

M.cache = {}

--- Sentinel text written into the buffer for the section separator.
--- The mutator checks for this exact string to detect section boundaries.
M.separator = "----- backlog -----"

--- Namespace for highlights, separator overlay, and general extmarks.
M.ns = vim.api.nvim_create_namespace("JiraOilList")

--- Dedicated namespace for inline virtual-text key extmarks so they can
--- be queried independently without iterating all extmarks.
M.ns_keys = vim.api.nvim_create_namespace("JiraOilKeys")

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

  -- Section separator
  hl("JiraOilSectionRule",  { link = "WinSeparator" })
  hl("JiraOilSectionLabel", { link = "Title" })
  hl("JiraOilSectionCount", { link = "Comment" })

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
-- Rendering helpers
-- ---------------------------------------------------------------------------

--- Build the styled separator overlay chunks for a section boundary.
---@param label string  e.g. "Backlog"
---@param count number|nil
---@return table[] chunks  for virt_text
local function build_separator_chunks(label, count)
  local sections = config.options.view.sections or {}
  local show_count = sections.show_count ~= false
  local chunks = {}

  table.insert(chunks, { "── ", "JiraOilSectionRule" })
  table.insert(chunks, { label, "JiraOilSectionLabel" })
  if show_count and count then
    table.insert(chunks, { " (" .. count .. ")", "JiraOilSectionCount" })
  end
  table.insert(chunks, { " ", "JiraOilSectionRule" })

  -- Fill remaining width with rule characters.  We compute a generous
  -- width; if the window is narrower the virtual text will simply be
  -- clipped by Neovim.
  local text_width = 0
  for _, c in ipairs(chunks) do
    text_width = text_width + vim.api.nvim_strwidth(c[1])
  end
  local fill = math.max(0, 80 - text_width)
  if fill > 0 then
    table.insert(chunks, { string.rep("─", fill), "JiraOilSectionRule" })
  end

  return chunks
end

--- Apply all decorations to a rendered buffer: column highlights, key
--- virtual text, separator overlay, and winbar.
---@param buf number
---@param lines string[]           buffer text lines
---@param issue_keys (string|nil)[] parallel array: issue key per line, nil for non-issue lines
---@param sep_lnum number|nil       1-indexed line number of the separator (if present)
---@param sprint_count number
---@param backlog_count number
---@param target string
local function apply_decorations(buf, lines, issue_keys, sep_lnum, sprint_count, backlog_count, target)
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.ns_keys, 0, -1)

  local columns = config.options.view.columns
  local col_hl = config.options.view.column_highlights or {}
  local status_hl = config.options.view.status_highlights or {}
  local key_width = config.options.view.key_width or 12

  local sep = " │ "
  local sep_byte_len = #sep

  -- We store extmark_id -> issue_key so the mutator can resolve identity.
  local mark_keys = {}

  for lnum, line in ipairs(lines) do
    local row = lnum - 1 -- 0-indexed

    -- Key virtual text (inline, read-only)
    local key = issue_keys[lnum]
    if key then
      local padded = util.pad_right(key, key_width) .. " "
      local mark_id = vim.api.nvim_buf_set_extmark(buf, M.ns_keys, row, 0, {
        virt_text = { { padded, "JiraOilKey" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
      mark_keys[mark_id] = key
    elseif line ~= M.separator then
      -- New issue line (no key yet) — add empty padding so columns align
      local padded = string.rep(" ", key_width + 1)
      vim.api.nvim_buf_set_extmark(buf, M.ns_keys, row, 0, {
        virt_text = { { padded, "Normal" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
    end

    -- Separator overlay
    if line == M.separator then
      local sections = config.options.view.sections or {}
      local label = sections.backlog_label or "Backlog"
      local chunks = build_separator_chunks(label, backlog_count)
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
        virt_text = chunks,
        virt_text_pos = "overlay",
      })
    else
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

  -- Store the key mapping in the cache
  local data = M.cache[buf]
  if data then
    data.mark_keys = mark_keys
  end

  -- Sprint section header (placed as a virtual line above the first line)
  if target == "all" and sprint_count > 0 then
    local sections = config.options.view.sections or {}
    local label = sections.sprint_label or "Sprint"
    local chunks = build_separator_chunks(label, sprint_count)
    vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, {
      virt_lines = { chunks },
      virt_lines_above = true,
    })
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
    local wb = ""
    if project ~= "" then
      wb = wb .. "%#JiraOilWinbarProject# " .. project .. "%* "
      wb = wb .. "%#JiraOilWinbarSep#│%* "
    end
    wb = wb .. "%#JiraOilWinbar#" .. target_label .. "%* "
    wb = wb .. "%#JiraOilWinbarSep#│%* "
    wb = wb .. "%#JiraOilWinbarCount#" .. total .. " issue" .. (total == 1 and "" or "s") .. "%*"
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win].winbar = wb
    end
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

---Resolve the issue key for a given 0-indexed row by reading key extmarks.
---@param buf number
---@param row number 0-indexed line number
---@return string|nil key
function M.get_key_at_line(buf, row)
  local data = M.cache[buf]
  if not data or not data.mark_keys then return nil end

  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_keys, { row, 0 }, { row, 0 }, {})
  for _, mark in ipairs(marks) do
    local key = data.mark_keys[mark[1]]
    if key then return key end
  end
  return nil
end

---Build a full mapping of 0-indexed row -> issue key by reading all key
---extmarks.  Used by the mutator to resolve identity for every line.
---@param buf number
---@return table<number, string> row_to_key
function M.get_all_line_keys(buf)
  local data = M.cache[buf]
  if not data or not data.mark_keys then return {} end

  local row_to_key = {}
  local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_keys, 0, -1, {})
  for _, mark in ipairs(marks) do
    local key = data.mark_keys[mark[1]]
    if key then
      row_to_key[mark[2]] = key  -- mark[2] is the 0-indexed row
    end
  end
  return row_to_key
end

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
      table.insert(issue_keys, issue.key or nil)
      local parsed = parser.parse_line(line)
      if parsed then
        parsed.key = issue.key or ""
        parsed.section = section
        table.insert(structured, parsed)
      end
    end
  end

  local function finish(lines, issue_keys, structured, sprint_count, backlog_count)
    if not vim.api.nvim_buf_is_valid(buf) then return end

    M.cache[buf] = {
      uri = uri,
      target = target,
      original = structured,
      original_lines = vim.deepcopy(lines),
      original_keys = vim.deepcopy(issue_keys),
      mark_keys = {},  -- populated by apply_decorations
    }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].undolevels = old_undolevels

    apply_decorations(buf, lines, issue_keys, nil, sprint_count, backlog_count, target)
    actions.setup(buf)
  end

  if target == "all" then
    cli.get_sprint_issues(function(sprint_issues)
      cli.get_backlog_issues(function(backlog_issues)
        local lines = {}
        local issue_keys = {}
        local structured = {}

        render_section(sprint_issues, "sprint", lines, issue_keys, structured)

        -- Separator line
        table.insert(lines, M.separator)
        table.insert(issue_keys, nil) -- no key for the separator

        render_section(backlog_issues, "backlog", lines, issue_keys, structured)

        finish(lines, issue_keys, structured, #sprint_issues, #backlog_issues)
      end)
    end)
  else
    local fetcher = target == "sprint" and cli.get_sprint_issues or cli.get_backlog_issues
    fetcher(function(issues)
      local lines = {}
      local issue_keys = {}
      local structured = {}
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
    M.open(buf, data.uri)
  end
end

function M.reset(buf)
  local data = M.cache[buf]
  if not data or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if not data.original_lines then
    return
  end

  local lines = vim.deepcopy(data.original_lines)
  local issue_keys = vim.deepcopy(data.original_keys or {})

  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = old_undolevels

  -- Recount sections for the separator overlay
  local sprint_count, backlog_count = 0, 0
  local in_backlog = false
  for i, line in ipairs(lines) do
    if line == M.separator then
      in_backlog = true
    elseif issue_keys[i] then
      if in_backlog then
        backlog_count = backlog_count + 1
      else
        sprint_count = sprint_count + 1
      end
    end
  end

  apply_decorations(buf, lines, issue_keys, nil, sprint_count, backlog_count, data.target)
end

return M
