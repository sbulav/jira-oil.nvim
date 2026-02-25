local config = require("jira-oil.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("JiraOilHelp")

local function define_highlights()
  vim.api.nvim_set_hl(0, "JiraOilHelpTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "JiraOilHelpMode", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "JiraOilHelpHeader", { link = "WinSeparator", default = true })
  vim.api.nvim_set_hl(0, "JiraOilHelpKey", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "JiraOilHelpSep", { link = "WinSeparator", default = true })
  vim.api.nvim_set_hl(0, "JiraOilHelpDesc", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "JiraOilHelpFooter", { link = "Comment", default = true })
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("JiraOilHelpHighlights", { clear = true }),
  callback = define_highlights,
})

---@param rhs string|table|fun()
---@return string|fun() rhs
---@return table opts
---@return string|nil mode
local function resolve(rhs)
  if type(rhs) == "string" and vim.startswith(rhs, "actions.") then
    local action_name = vim.split(rhs, ".", { plain = true })[2]
    local actions = require("jira-oil.actions")
    local action = actions[action_name]
    if not action then
      vim.notify("[jira-oil] Unknown action name: " .. action_name, vim.log.levels.ERROR)
    end
    return resolve(action)
  elseif type(rhs) == "table" then
    local opts = vim.deepcopy(rhs)
    local mode = opts.mode

    -- Resolve the inner callback/action reference (only once)
    local inner = opts.callback or opts[1]
    local callback, parent_opts, parent_mode = resolve(inner)

    -- Inherit description from resolved action if not explicitly set
    if parent_opts.desc and not opts.desc then
      if opts.opts then
        opts.desc = string.format("%s %s", parent_opts.desc, vim.inspect(opts.opts):gsub("%s+", " "))
      else
        opts.desc = parent_opts.desc
      end
    end

    -- Merge any opts from the resolved action (user opts take priority via "keep")
    opts = vim.tbl_extend("keep", opts, parent_opts)
    mode = mode or parent_mode

    -- Clean up internal fields that shouldn't be passed to vim.keymap.set
    opts.callback = nil
    opts.mode = nil
    opts[1] = nil
    opts.deprecated = nil
    opts.parameters = nil

    -- Wrap callback with extra arguments if specified
    if opts.opts and type(callback) == "function" then
      local callback_args = opts.opts
      opts.opts = nil
      local orig_callback = callback
      callback = function()
        ---@diagnostic disable-next-line: redundant-parameter
        orig_callback(callback_args)
      end
    end

    return callback, opts, mode
  else
    return rhs, {}
  end
end

---@param keymaps table<string, string|table|fun()>
---@param bufnr integer
M.set_keymaps = function(keymaps, bufnr)
  for k, v in pairs(keymaps) do
    local rhs, opts, mode = resolve(v)
    if rhs then
      vim.keymap.set(mode or "", k, rhs, vim.tbl_extend("keep", { buffer = bufnr }, opts))
    end
  end
end

local function pad_align(str, width)
  local pad = width - vim.api.nvim_strwidth(str)
  if pad <= 0 then
    return str
  end
  return str .. string.rep(" ", pad)
end

---@param mode string
---@return string
local function mode_name(mode)
  local names = {
    n = "Normal",
    i = "Insert",
    v = "Visual",
    x = "Visual",
    s = "Select",
    o = "Operator",
    c = "Command",
    t = "Terminal",
  }
  return names[mode] or string.upper(mode)
end

---@param mode string|table|nil
---@return string[]
local function normalize_modes(mode)
  if mode == nil then
    return { "n" }
  end
  if type(mode) == "string" then
    return { mode }
  end
  local out = {}
  local seen = {}
  for _, m in ipairs(mode) do
    if type(m) == "string" and not seen[m] then
      seen[m] = true
      table.insert(out, m)
    end
  end
  if #out == 0 then
    return { "n" }
  end
  return out
end

---@param mode string
---@return number
local function mode_sort_key(mode)
  local order = {
    n = 1,
    i = 2,
    v = 3,
    x = 4,
    s = 5,
    o = 6,
    c = 7,
    t = 8,
  }
  return order[mode] or 99
end

---@param keymaps table<string, string|table|fun()>
---@param opts? { context?: string }
M.show_help = function(keymaps, opts)
  opts = opts or {}
  local help_cfg = config.options.keymaps_help or {}

  local rhs_to_lhs = {}
  local lhs_to_all_lhs = {}
  for k, rhs in pairs(keymaps) do
    if rhs then
      if rhs_to_lhs[rhs] then
        local first_lhs = rhs_to_lhs[rhs]
        table.insert(lhs_to_all_lhs[first_lhs], k)
      else
        rhs_to_lhs[rhs] = k
        lhs_to_all_lhs[k] = { k }
      end
    end
  end

  local max_lhs = help_cfg.key_width or 18
  local keymap_entries = {}
  for k, rhs in pairs(keymaps) do
    local all_lhs = lhs_to_all_lhs[k]
    if all_lhs then
      local _, resolved_opts, mode = resolve(rhs)
      local keystr = table.concat(all_lhs, "/")
      max_lhs = math.max(max_lhs, vim.api.nvim_strwidth(keystr))
      for _, m in ipairs(normalize_modes(mode)) do
        table.insert(keymap_entries, {
          mode = m,
          str = keystr,
          all_lhs = all_lhs,
          desc = resolved_opts.desc or "",
        })
      end
    end
  end
  table.sort(keymap_entries, function(a, b)
    local am = mode_sort_key(a.mode)
    local bm = mode_sort_key(b.mode)
    if am ~= bm then
      return am < bm
    end
    if a.desc ~= b.desc then
      return a.desc < b.desc
    end
    return a.str < b.str
  end)

  local mode_icons = vim.tbl_extend("keep", help_cfg.icons or {}, {
    n = "\u{f489}", -- nf-md-cursor_default
    i = "\u{f040}", -- nf-fa-pencil
    v = "\u{f245}", -- nf-fa-mouse_pointer
    x = "\u{f245}", -- nf-fa-mouse_pointer
    s = "\u{f245}", -- nf-fa-mouse_pointer
    o = "\u{f12e}", -- nf-fa-puzzle_piece
    c = "\u{f120}", -- nf-fa-terminal
    t = "\u{f120}", -- nf-fa-terminal
    default = "\u{f128}", -- nf-fa-question
  })
  local separator = help_cfg.separator or " \u{2502} "
  local key_prefix = " " .. pad_align("KEY", max_lhs) .. separator
  local key_prefix_width = vim.api.nvim_strwidth(key_prefix)

  local rows = {}
  local function add_row(kind, data)
    data = data or {}
    data.kind = kind
    table.insert(rows, data)
  end

  if help_cfg.show_title ~= false then
    local title = " JiraOil Keymaps"
    if opts.context and opts.context ~= "" then
      title = title .. " - " .. opts.context
    end
    add_row("title", { text = title })
    add_row("spacer")
  end

  local grouped = {}
  for _, entry in ipairs(keymap_entries) do
    grouped[entry.mode] = grouped[entry.mode] or {}
    table.insert(grouped[entry.mode], entry)
  end

  local modes = {}
  for mode, _ in pairs(grouped) do
    table.insert(modes, mode)
  end
  table.sort(modes, function(a, b)
    local am = mode_sort_key(a)
    local bm = mode_sort_key(b)
    if am ~= bm then
      return am < bm
    end
    return a < b
  end)

  for _, mode in ipairs(modes) do
    local icon = mode_icons[mode] or mode_icons.default or ""
    local title = string.format(" %s %s mode", icon, mode_name(mode))
    add_row("mode", { text = title })
    add_row("header", { text = "DESCRIPTION" })

    for _, entry in ipairs(grouped[mode]) do
      add_row("entry", {
        key = entry.str,
        all_lhs = entry.all_lhs,
        text = entry.desc,
      })
    end
    add_row("spacer")
  end

  if #rows > 0 and rows[#rows].kind == "spacer" then
    table.remove(rows, #rows)
  end

  if help_cfg.show_footer ~= false then
    if #rows > 0 then
      add_row("spacer")
    end
    add_row("footer", { text = " Press q or <C-c> to close" })
  end

  local lines = {}
  local max_line = 1
  for _, row in ipairs(rows) do
    local line = row.text or ""
    if row.kind == "entry" or row.kind == "header" then
      max_line = math.max(max_line, key_prefix_width + vim.api.nvim_strwidth(line))
    else
      max_line = math.max(max_line, vim.api.nvim_strwidth(line))
    end
    table.insert(lines, line)
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for i, row in ipairs(rows) do
    local lnum = i - 1
    if row.kind == "title" then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        end_col = #lines[i],
        hl_group = "JiraOilHelpTitle",
      })
    elseif row.kind == "mode" then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        virt_text = { { row.text or "", "JiraOilHelpMode" } },
        virt_text_pos = "overlay",
      })
    elseif row.kind == "header" then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        virt_text = {
          { " " .. pad_align("KEY", max_lhs), "JiraOilHelpHeader" },
          { separator, "JiraOilHelpSep" },
        },
        virt_text_pos = "inline",
        right_gravity = false,
      })
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        end_col = #lines[i],
        hl_group = "JiraOilHelpHeader",
      })
    elseif row.kind == "entry" then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        virt_text = {
          { " " .. pad_align(row.key or "", max_lhs), "JiraOilHelpKey" },
          { separator, "JiraOilHelpSep" },
        },
        virt_text_pos = "inline",
        right_gravity = false,
      })
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        end_col = #lines[i],
        hl_group = "JiraOilHelpDesc",
      })
    elseif row.kind == "footer" then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum, 0, {
        end_col = #lines[i],
        hl_group = "JiraOilHelpFooter",
      })
    end
  end

  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = bufnr })
  vim.keymap.set("n", "<c-c>", "<cmd>close<CR>", { buffer = bufnr })
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "jira-oil-help"

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - vim.o.cmdheight
  if editor_height < 1 then
    editor_height = vim.o.lines
  end
  local max_width = math.max(20, math.floor(editor_width * (help_cfg.max_width_ratio or 0.9)))
  local max_height = math.max(4, math.floor(editor_height * (help_cfg.max_height_ratio or 0.8)))
  local width = math.min(max_width, max_line + 1)
  local height = math.min(max_height, #lines)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((editor_height - height) / 2)),
    col = math.max(0, math.floor((editor_width - width) / 2)),
    width = width,
    height = height,
    zindex = help_cfg.zindex or 150,
    style = "minimal",
    border = help_cfg.border,
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.api.nvim_create_autocmd("BufLeave", {
    callback = close,
    once = true,
    nested = true,
    buffer = bufnr,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    callback = close,
    once = true,
    nested = true,
  })
end

return M
