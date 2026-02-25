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
      vim.cmd.edit("jira-oil://issue/" .. key)
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
  if normalize_reg(yank.regname) ~= normalize_reg(reg) then
    return {}
  end
  if #yank.lines == 0 or #yank.entries == 0 then
    return {}
  end
  if table.concat(yank.lines, "\n") ~= table.concat(pasted_lines, "\n") then
    return {}
  end

  local out = {}
  for i = 1, #pasted_lines do
    local base = yank.entries[((i - 1) % #yank.entries) + 1]
    out[i] = base
  end
  return out
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
