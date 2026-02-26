-- Lazy requires to avoid circular dependency: view -> actions -> mutator -> view
local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local parser = require("jira-oil.parser")

local M = {}

---@param buf number
---@return string|nil
local function current_issue_key(buf)
  local kind = vim.b[buf].jira_oil_kind
  if kind == "issue" then
    local scratch = require("jira-oil.scratch")
    local data = scratch.cache and scratch.cache[buf]
    local key = data and data.key or nil
    if key == "new" then
      return nil
    end
    return key
  end

  local view = require("jira-oil.view")
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return view.get_key_at_line(buf, row)
end

---@param buf number
---@return string[]
local function selected_issue_keys(buf)
  if vim.b[buf].jira_oil_kind ~= "list" then
    local key = current_issue_key(buf)
    return key and { key } or {}
  end

  local mode = vim.fn.mode()
  local is_visual = mode == "v" or mode == "V" or mode == "\022"
  if not is_visual then
    local key = current_issue_key(buf)
    return key and { key } or {}
  end

  local view = require("jira-oil.view")
  local first = vim.fn.getpos("'<")[2]
  local last = vim.fn.getpos("'>")[2]
  if first == 0 or last == 0 then
    local key = current_issue_key(buf)
    return key and { key } or {}
  end
  if first > last then
    first, last = last, first
  end

  local keys = {}
  local seen = {}
  for lnum = first, last do
    local key = view.get_key_at_line(buf, lnum - 1)
    if key and key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(keys, key)
    end
  end
  return keys
end

M.select = {
  desc = "Open Jira issue",
  callback = function()
    local view = require("jira-oil.view")
    local scratch = require("jira-oil.scratch")
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
    local key = view.get_key_at_line(buf, row)
    if key and key ~= "" then
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      local parsed = parser.parse_line(line)
      scratch.open_existing(key, parsed)
      return
    end

    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local parsed = parser.parse_line(line)
    if not parsed then
      return
    end

    if (parsed.summary or "") == "" then
      vim.notify("Summary is empty for new task.", vim.log.levels.WARN)
      return
    end

    local source_key = view.get_copy_source_at_line(buf, row)
    if not source_key or source_key == "" then
      source_key = fallback_source_from_last_yank(line)
    end
    scratch.open_new({
      source_key = source_key,
      row_fields = parsed,
    })
  end,
}

M.create = {
  desc = "Create new Jira issue",
  callback = function()
    vim.cmd.edit("jira-oil://issue/new")
  end,
}

M.refresh = {
  desc = "Refresh Jira issues",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    require("jira-oil.view").refresh(buf)
  end,
}

M.save = {
  desc = "Save Jira changes",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    if vim.b[buf].jira_oil_kind == "issue" then
      require("jira-oil.scratch").save(buf)
    else
      require("jira-oil.mutator").save(buf)
    end
  end,
}

M.reset = {
  desc = "Reset unsaved changes",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    if vim.b[buf].jira_oil_kind == "issue" then
      require("jira-oil.scratch").reset(buf)
    else
      require("jira-oil.scratch").clear_all_drafts()
      require("jira-oil.view").reset(buf)
    end
  end,
}

M.pick_epic = {
  desc = "Select epic",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    require("jira-oil.scratch").pick_epic(buf)
  end,
}

M.pick_components = {
  desc = "Select components",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    require("jira-oil.scratch").pick_components(buf)
  end,
}

M.close = {
  desc = "Close Jira buffer",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    if vim.b[buf].jira_oil_kind == "issue" then
      require("jira-oil.scratch").capture_draft(buf)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end,
}

M.show_help = {
  desc = "Show keymaps help",
  callback = function()
    local keymap_util = require("jira-oil.keymap_util")
    local buf = vim.api.nvim_get_current_buf()
    local kind = vim.b[buf].jira_oil_kind == "issue" and "Issue" or "List"
    local keymaps = config.options.keymaps
    if vim.b[buf].jira_oil_kind == "issue" then
      keymaps = config.options.keymaps_issue
    end
    keymap_util.show_help(keymaps, { context = kind })
  end,
}

M.open_in_browser = {
  desc = "Open issue in browser",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    local key = current_issue_key(buf)
    if not key or key == "" then
      vim.notify("No Jira issue key on current line.", vim.log.levels.WARN)
      return
    end

    cli.exec({ "open", key }, function(_, stderr, code)
      if code ~= 0 then
        vim.notify("Failed to open issue in browser: " .. (stderr or ""), vim.log.levels.ERROR)
      end
    end)
  end,
}

M.yank_issue_key = {
  desc = "Yank issue key",
  callback = function(opts)
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    local keys = selected_issue_keys(buf)
    if #keys == 0 then
      vim.notify("No Jira issue key to yank.", vim.log.levels.WARN)
      return
    end

    local text = table.concat(keys, "\n")
    vim.fn.setreg('"', text)
    vim.fn.setreg("+", text)

    if #keys == 1 then
      vim.notify("Yanked Jira issue key: " .. keys[1])
    else
      vim.notify("Yanked " .. #keys .. " Jira issue keys")
    end
  end,
}

---@param reg string
---@return string[]
local function get_reg_lines(reg)
  local lines = vim.fn.getreg(reg, 1, true)
  if type(lines) == "string" then
    return { lines }
  end
  return lines or {}
end

---@param key string
---@return string
local function normalize_reg(key)
  if key == nil or key == "" then
    return '"'
  end
  return key
end

---@param pasted_lines string[]
---@param reg string
---@return table[]
local function source_entries_for_paste(pasted_lines, reg)
  local view = require("jira-oil.view")
  local yank = view.last_yank
  if not yank then
    return {}
  end
  if #yank.lines == 0 or #yank.entries == 0 then
    return {}
  end

  local out = {}
  for i = 1, #pasted_lines do
    local base = yank.entries[((i - 1) % #yank.entries) + 1]
    out[i] = base
  end
  return out
end

---@param line string
---@return string|nil
local function fallback_source_from_last_yank(line)
  local view = require("jira-oil.view")
  local yank = view.last_yank
  if not yank or not yank.entries then
    return nil
  end
  for _, entry in ipairs(yank.entries) do
    if entry.line == line and entry.source_key and entry.source_key ~= "" then
      return entry.source_key
    end
  end
  return nil
end

---@param lines string[]
---@param section string
---@return integer|nil
local function section_header_row(lines, section)
  local view = require("jira-oil.view")
  local header = section == "backlog" and view.header_backlog or view.header_sprint
  for i, line in ipairs(lines) do
    if line == header then
      return i - 1
    end
  end
  return nil
end

---@param lines string[]
---@param row integer
---@param target string
---@return string|nil
local function section_for_row(lines, row, target)
  local view = require("jira-oil.view")
  local current = target == "backlog" and "backlog" or "sprint"
  for i = 1, math.min(#lines, row + 1) do
    local line = lines[i]
    if line == view.header_backlog then
      current = "backlog"
    elseif line == view.header_sprint then
      current = "sprint"
    end
  end
  return current
end

---@param row_map table<number, string>
---@param moved_row integer
---@param insert_row integer
---@return table<number, string>
local function remap_rows_after_move(row_map, moved_row, insert_row)
  local remapped = {}
  for row, value in pairs(row_map or {}) do
    if row ~= moved_row then
      local row_after_delete = row
      if row > moved_row then
        row_after_delete = row - 1
      end

      local row_after_insert = row_after_delete
      if row_after_delete >= insert_row then
        row_after_insert = row_after_delete + 1
      end
      remapped[row_after_insert] = value
    end
  end

  local moved_value = row_map and row_map[moved_row] or nil
  if moved_value and moved_value ~= "" then
    remapped[insert_row] = moved_value
  end
  return remapped
end

---@param key string
---@param before boolean
local function paste_with_metadata(key, before)
  local view = require("jira-oil.view")
  local buf = vim.api.nvim_get_current_buf()
  local before_keys = view.get_all_line_keys(buf)
  local before_sources = view.get_all_copy_sources(buf)
  local reg = normalize_reg(key)
  local lines = get_reg_lines(reg)
  local regtype = vim.fn.getregtype(reg)
  local count = math.max(vim.v.count1, 1)
  local row_before = vim.api.nvim_win_get_cursor(0)[1] - 1

  local normal_cmd = tostring(count) .. '"' .. reg .. (before and "P" or "p")
  vim.cmd.normal({ args = { normal_cmd }, bang = true })

  if vim.b[buf].jira_oil_kind ~= "list" then
    return
  end

  if not regtype or regtype:sub(1, 1) ~= "V" then
    view.decorate_current(buf)
    return
  end

  local per_paste = #lines
  if per_paste == 0 then
    return
  end
  local inserted = per_paste * count
  local start_row = before and row_before or (row_before + 1)

  local remapped_keys = {}
  for row, issue_key in pairs(before_keys) do
    if row < start_row then
      remapped_keys[row] = issue_key
    else
      remapped_keys[row + inserted] = issue_key
    end
  end
  view.replace_all_line_keys(buf, remapped_keys)

  local remapped_sources = {}
  for row, source_key in pairs(before_sources) do
    if row < start_row then
      remapped_sources[row] = source_key
    else
      remapped_sources[row + inserted] = source_key
    end
  end

  local src = source_entries_for_paste(lines, reg)
  for i = 1, inserted do
    local row = start_row + i - 1
    local base = src[((i - 1) % math.max(#src, 1)) + 1]
    local source_key = base and (base.source_key or base.key) or nil
    if source_key and source_key ~= "" then
      remapped_sources[row] = source_key
    end
  end
  view.replace_all_copy_sources(buf, remapped_sources)

  view.decorate_current(buf)
end

M.paste_after = {
  desc = "Paste task copy after cursor",
  callback = function()
    paste_with_metadata(vim.v.register, false)
  end,
}

M.paste_before = {
  desc = "Paste task copy before cursor",
  callback = function()
    paste_with_metadata(vim.v.register, true)
  end,
}

M.move_issue_to_other_section = {
  desc = "Move issue sprint/backlog",
  callback = function(opts)
    local view = require("jira-oil.view")
    local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
    if vim.b[buf].jira_oil_kind ~= "list" then
      return
    end

    local data = view.cache[buf]
    if not data then
      return
    end

    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local key = view.get_key_at_line(buf, row)
    if not key or key == "" then
      vim.notify("No Jira issue on current line.", vim.log.levels.WARN)
      return
    end

    if data.target ~= "all" then
      vim.cmd.normal({ args = { "dd" }, bang = true })
      view.decorate_current(buf)
      vim.notify("Issue removed from current view. Open jira-oil://all to drag between Sprint and Backlog.", vim.log.levels.INFO)
      return
    end

    local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local moved_line = lines_before[row + 1]
    if not moved_line then
      return
    end

    local from_section = section_for_row(lines_before, row, data.target)
    local to_section = from_section == "sprint" and "backlog" or "sprint"

    local keys_before = view.get_all_line_keys(buf)
    local sources_before = view.get_all_copy_sources(buf)

    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, {})
    local lines_after_delete = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local header_row = section_header_row(lines_after_delete, to_section)
    if header_row == nil then
      vim.api.nvim_buf_set_lines(buf, row, row, false, { moved_line })
      view.replace_all_line_keys(buf, keys_before)
      view.replace_all_copy_sources(buf, sources_before)
      view.decorate_current(buf)
      vim.notify("Destination section not found.", vim.log.levels.ERROR)
      return
    end

    local insert_row = header_row + 1
    vim.api.nvim_buf_set_lines(buf, insert_row, insert_row, false, { moved_line })

    local remapped_keys = remap_rows_after_move(keys_before, row, insert_row)
    local remapped_sources = remap_rows_after_move(sources_before, row, insert_row)
    view.replace_all_line_keys(buf, remapped_keys)
    view.replace_all_copy_sources(buf, remapped_sources)

    vim.api.nvim_win_set_cursor(0, { insert_row + 1, 0 })
    view.decorate_current(buf)
    vim.notify("Moved " .. key .. " to " .. (to_section == "sprint" and "Sprint" or "Backlog") .. " [draft]", vim.log.levels.INFO)
  end,
}

---@param buf number
function M.on_text_yank_post(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.b[buf].jira_oil_kind ~= "list" then
    return
  end

  local event = vim.v.event or {}
  if event.operator ~= "y" then
    return
  end

  local lines = event.regcontents or {}
  if #lines == 0 then
    return
  end

  local start_row = vim.fn.getpos("'[")[2] - 1
  local end_row = vim.fn.getpos("']")[2] - 1
  if start_row < 0 or end_row < 0 then
    return
  end
  if start_row > end_row then
    start_row, end_row = end_row, start_row
  end

  local view = require("jira-oil.view")
  local keys = view.get_all_line_keys(buf)
  local copied = view.get_all_copy_sources(buf)
  local entries = {}
  local i = 1
  for row = start_row, end_row do
    local source_key = copied[row] or keys[row]
    local line = lines[i] or ""
    entries[i] = {
      line = line,
      key = keys[row],
      source_key = source_key,
    }
    i = i + 1
  end

  view.last_yank = {
    regname = normalize_reg(event.regname),
    regtype = event.regtype or "",
    lines = vim.deepcopy(lines),
    entries = entries,
  }
end

---@param buf number
function M.setup(buf)
  local keymap_util = require("jira-oil.keymap_util")
  keymap_util.set_keymaps(config.options.keymaps, buf)
end

---@param buf number
function M.setup_issue(buf)
  local keymap_util = require("jira-oil.keymap_util")
  keymap_util.set_keymaps(config.options.keymaps_issue, buf)
end

return M
