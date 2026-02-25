-- Lazy requires to avoid circular dependency: view -> actions -> mutator -> view
local config = require("jira-oil.config")
local cli = require("jira-oil.cli")

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
    local buf = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
    local key = view.get_key_at_line(buf, row)
    if key and key ~= "" then
      vim.cmd.edit("jira-oil://issue/" .. key)
    end
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
