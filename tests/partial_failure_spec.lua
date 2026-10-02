local t = require("minitest")
local cli = require("jira-oil.cli")
local view = require("jira-oil.view")
local parser = require("jira-oil.parser")
local mutator = require("jira-oil.mutator")
local h = require("helpers")

---Run `fn` with jira-cli stubbed: `fail(args)` decides which commands fail,
---creates print a browse URL for PROJ-99. Returns the executed commands and
---how often the view was refreshed.
local function with_cli(fail, fn)
  local calls, refreshes = {}, 0
  h.stub(cli, "exec", function(args, cb)
    table.insert(calls, table.concat(args, " "))
    if fail(args) then
      cb("", "boom", 1)
    elseif args[2] == "create" then
      cb("https://example.atlassian.net/browse/PROJ-99", "", 0)
    else
      cb("", "", 0)
    end
  end, function()
    h.stub(cli, "clear_cache", function() end, function()
      h.stub(view, "refresh", function()
        refreshes = refreshes + 1
      end, fn)
    end)
  end)
  return calls, refreshes
end

-- Edit in place (like a user would) so the row's key extmark survives.
local function edit_summary(buf, row, from, to)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local s, e = line:find(from, 1, true)
  vim.api.nvim_buf_set_text(buf, row, s - 1, row, e, { to })
end

local function three_edited_rows()
  local buf = h.list_buf({
    { key = "PROJ-1", summary = "one" },
    { key = "PROJ-2", summary = "two" },
    { key = "PROJ-3", summary = "three" },
  })
  edit_summary(buf, 0, "one", "ONE")
  edit_summary(buf, 1, "two", "TWO")
  edit_summary(buf, 2, "three", "THREE")
  vim.bo[buf].modified = true
  return buf
end

t.test("partial failure: stops at the first failing change", function()
  local buf = three_edited_rows()
  local calls, refreshes = with_cli(function(args)
    return args[3] == "PROJ-2"
  end, function()
    mutator.execute_mutations(buf, mutator.compute_diff(buf))
  end)
  t.eq(#calls, 2)
  t.ok(calls[2]:match("PROJ%-2"), "second call should be PROJ-2")
  t.eq(refreshes, 0)
  t.eq(vim.bo[buf].modified, true)
end)

t.test("partial failure: a re-save retries only what was not applied", function()
  local buf = three_edited_rows()
  with_cli(function(args)
    return args[3] == "PROJ-2"
  end, function()
    mutator.execute_mutations(buf, mutator.compute_diff(buf))
  end)
  local keys = {}
  for _, m in ipairs(mutator.compute_diff(buf)) do
    table.insert(keys, m.key)
  end
  t.eq(keys, { "PROJ-2", "PROJ-3" })
end)

t.test("partial failure: a successful create is never repeated", function()
  local buf = h.list_buf({ { key = "PROJ-0", summary = "zero" }, { key = "PROJ-1", summary = "one" } })
  local new_line = parser.format_line({
    fields = { status = { name = "To Do" }, summary = "brand new", assignee = { displayName = "A" } },
  })
  -- Open a line below row 0 (like `o`) so the create runs before the failing edit.
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  vim.api.nvim_buf_set_text(buf, 0, #first, 0, #first, { "", new_line })
  edit_summary(buf, 2, "one", "ONE")

  with_cli(function(args)
    return args[2] == "edit"
  end, function()
    mutator.execute_mutations(buf, mutator.compute_diff(buf))
  end)

  t.eq(view.get_key_at_line(buf, 1), "PROJ-99")
  local retry = mutator.compute_diff(buf)
  t.eq(#retry, 1)
  t.eq(retry[1].type, "UPDATE")
  t.eq(retry[1].key, "PROJ-1")
end)

t.test("partial failure: a clean save still refreshes and clears modified", function()
  local buf = three_edited_rows()
  local calls, refreshes = with_cli(function()
    return false
  end, function()
    mutator.execute_mutations(buf, mutator.compute_diff(buf))
  end)
  t.eq(#calls, 3)
  t.eq(refreshes, 1)
  t.eq(vim.bo[buf].modified, false)
end)
