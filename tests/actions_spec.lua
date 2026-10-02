local t = require("minitest")
local actions = require("jira-oil.actions")
local scratch = require("jira-oil.scratch")
local h = require("helpers")

t.test("select: <CR> on a new row opens a new-issue buffer", function()
  local buf = h.list_buf({ { key = "PROJ-1", summary = "existing" } })
  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "Open            │ me              │ new summary" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local opened
  h.stub(scratch, "open_new", function(prefill)
    opened = prefill
  end, function()
    actions.select.callback()
  end)

  t.ok(opened ~= nil, "open_new was not called")
  t.eq(opened.row_fields.summary, "new summary")
end)
