local t = require("minitest")
local config = require("jira-oil.config")
local actions = require("jira-oil.actions")
local completion = require("jira-oil.completion")
local scratch = require("jira-oil.scratch")
local mutator = require("jira-oil.mutator")
local parser = require("jira-oil.parser")
local view = require("jira-oil.view")
local cli = require("jira-oil.cli")
local h = require("helpers")

local function with_workflow(opts, fn)
  local saved, drafts = config.options, scratch.drafts
  local previous = vim.api.nvim_get_current_buf()
  config.setup(opts)
  scratch.drafts = {}
  local buf = h.list_buf({ { key = "PROJ-1", status = config.options.defaults.status, summary = "existing" } })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ok, err = pcall(fn, buf)
  config.options, scratch.drafts = saved, drafts
  vim.api.nvim_set_current_buf(previous)
  view.cache[buf], view.mark_keys[buf] = nil, nil
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err) end
end

local custom = { defaults = { status = "Ready", close_status = "Resolved" }, statuses = { "Ready", "Doing", "Resolved" } }

t.test("status config: queued removals use the configured close status", function()
  with_workflow(custom, function(buf)
    actions.queue_removal.callback()
    t.eq(mutator.compute_diff(buf)[1].item.status, "Resolved")
  end)
end)

t.test("status config: new blank-status rows use defaults.status", function()
  with_workflow(custom, function(buf)
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "                │                 │ new issue" })
    local mutations = mutator.compute_diff(buf)
    t.eq(#mutations, 1)
    t.eq(mutations[1].type, "CREATE")
    t.eq(mutations[1].item.status, "Ready")
  end)
end)

t.test("status config: cycling and completion use exactly the configured list", function()
  with_workflow(custom, function()
    for _, expected in ipairs({ "Doing", "Resolved", "Ready" }) do
      actions.cycle_status.callback()
      t.eq(parser.parse_line(vim.api.nvim_get_current_line()).status, expected)
    end
    local names = {}
    for _, item in ipairs(completion.omnifunc(0, "")) do table.insert(names, item.word) end
    t.eq(names, custom.statuses)
    t.eq(completion.omnifunc(0, "Do"), { { word = "Doing", menu = "[Status]" } })
  end)
end)

t.test("status config: an empty list disables cycling and completion", function()
  with_workflow({ statuses = {} }, function()
    local before = vim.api.nvim_get_current_line()
    actions.cycle_status.callback()
    t.eq(vim.api.nvim_get_current_line(), before)
    t.eq(completion.omnifunc(0, ""), {})
  end)
end)

t.test("status config: default close and status list remain unchanged", function()
  with_workflow({}, function(buf)
    t.eq(config.options.statuses, { "Open", "To Do", "In Progress", "In Review", "Done", "Closed", "Blocked" })
    actions.cycle_status.callback()
    t.eq(parser.parse_line(vim.api.nvim_get_current_line()).status, "To Do")
    actions.queue_removal.callback()
    t.eq(mutator.compute_diff(buf)[1].item.status, "Closed")
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "                │                 │ new issue" })
    t.eq(mutator.compute_diff(buf)[2].item.status, "Open")
  end)
end)

t.test("status config: To Do is transitioned explicitly when it is not the configured initial status", function()
  with_workflow(custom, function(buf)
    local calls = {}
    h.stub(cli, "exec", function(args, cb)
      table.insert(calls, args)
      cb("https://example.test/browse/PROJ-99", "", 0)
    end, function()
      h.stub(view, "refresh", function() end, function()
        h.stub(vim, "defer_fn", function() end, function()
          mutator.execute_mutations(buf, { { type = "CREATE", item = { status = "To Do", summary = "new", type = "Task" } } })
        end)
      end)
    end)
    t.eq(calls[2], { "issue", "move", "PROJ-99", "To Do" })
  end)
end)
