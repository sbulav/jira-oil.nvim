local cli = require("jira-oil.cli")
local parser = require("jira-oil.parser")
local config = require("jira-oil.config")
local actions = require("jira-oil.actions")
local util = require("jira-oil.util")

local M = {}

M.cache = {}
M.separator = "----- backlog -----"
M.ns = vim.api.nvim_create_namespace("JiraOilList")

local function ensure_highlights()
  if M._highlights_set then
    return
  end
  M._highlights_set = true

  vim.api.nvim_set_hl(0, "JiraOilKey", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "JiraOilStatus", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "JiraOilAssignee", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "JiraOilSummary", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "JiraOilSeparator", { link = "Comment", default = true })

  vim.api.nvim_set_hl(0, "JiraOilStatusOpen", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "JiraOilStatusInProgress", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "JiraOilStatusInReview", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "JiraOilStatusDone", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "JiraOilStatusBlocked", { link = "DiagnosticError", default = true })
end

local function apply_highlights(buf, lines)
  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)

  local columns = config.options.view.columns
  local col_hl = config.options.view.column_highlights or {}
  local status_hl = config.options.view.status_highlights or {}
  local sep_hl = config.options.view.separator_highlight or "JiraOilSeparator"

  local sep = " │ "
  local sep_len = #sep

  for lnum, line in ipairs(lines) do
    if line == M.separator then
      vim.api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, 0, {
        end_col = #line,
        hl_group = sep_hl,
      })
    else
      local parts = vim.split(line, sep, { plain = true })
      local start_col = 0
      for idx, col in ipairs(columns) do
        local part = parts[idx] or ""
        local width = #part
        local hl_group = col_hl[col.name] or "Normal"
        if col.name == "status" then
          local status = util.trim(part)
          if status ~= "" and status_hl[status] then
            hl_group = status_hl[status]
          end
        end
        if width > 0 then
          vim.api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, start_col, {
            end_col = start_col + width,
            hl_group = hl_group,
          })
        end
        start_col = start_col + width + sep_len
      end
    end
  end
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
      original_lines = vim.deepcopy(lines),
    }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.bo[buf].undolevels = old_undolevels

    apply_highlights(buf, lines)
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

function M.reset(buf)
  local data = M.cache[buf]
  if not data or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if not data.original_lines then
    return
  end

  local lines = vim.deepcopy(data.original_lines)

  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].undolevels = old_undolevels
  apply_highlights(buf, lines)
end

return M
