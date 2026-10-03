local t = require("minitest")
local actions = require("jira-oil.actions")
local scratch = require("jira-oil.scratch")
local mutator = require("jira-oil.mutator")
local view = require("jira-oil.view")
local parser = require("jira-oil.parser")
local h = require("helpers")

local function with_row(fn)
  local previous = vim.api.nvim_get_current_buf()
  local drafts = scratch.drafts
  scratch.drafts = {}
  local buf = h.list_buf({ { key = "PROJ-1", summary = "existing" } })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ok, err = pcall(fn, buf)
  scratch.drafts = drafts
  vim.api.nvim_set_current_buf(previous)
  view.cache[buf], view.mark_keys[buf] = nil, nil
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err) end
end

t.test("cycle status: queued removals remain safe and queued", function()
  with_row(function(buf)
    actions.queue_removal.callback()
    local draft = vim.deepcopy(scratch.peek_draft("PROJ-1"))
    t.is_nil(draft.parsed)
    actions.cycle_status.callback()
    t.eq(scratch.peek_draft("PROJ-1"), draft)
    t.eq(mutator.compute_diff(buf)[1].item.status, "Closed")
  end)
end)

t.test("cycle status: five presses preserve display width and other columns", function()
  with_row(function(buf)
    local before = vim.split(vim.api.nvim_get_current_line(), "│", { plain = true })
    for _ = 1, 5 do
      actions.cycle_status.callback()
      local after = vim.split(vim.api.nvim_get_current_line(), "│", { plain = true })
      t.eq(vim.api.nvim_strwidth(after[1]), vim.api.nvim_strwidth(before[1]))
      t.eq(after[2], before[2])
      t.eq(after[3], before[3])
    end
    t.eq(parser.parse_line(vim.api.nvim_get_current_line()).status, "Closed")
    t.eq(mutator.compute_diff(buf)[1].item.status, "Closed")
    t.is_nil(scratch.peek_draft("PROJ-1"))
  end)
end)

t.test("cycle status: typing after cycling controls the computed mutation", function()
  with_row(function(buf)
    actions.cycle_status.callback()
    local parts = vim.split(vim.api.nvim_get_current_line(), "│", { plain = true })
    parts[1] = "Blocked         "
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { table.concat(parts, "│") })
    t.eq(mutator.compute_diff(buf)[1].item.status, "Blocked")
    t.is_nil(scratch.peek_draft("PROJ-1"))
  end)
end)
