local t = require("minitest")
local h = require("helpers")
local actions = require("jira-oil.actions")
local cli = require("jira-oil.cli")
local jira = require("jira-oil")
local mutator = require("jira-oil.mutator")
local parser = require("jira-oil.parser")
local scratch = require("jira-oil.scratch")
local view = require("jira-oil.view")

local function with_list(fn)
  local previous = vim.api.nvim_get_current_buf()
  local initial_buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    initial_buffers[buf] = true
  end
  local group = vim.api.nvim_create_augroup("JiraOilUnsavedTests", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "jira-oil://*",
    callback = function(args)
      view.open(args.buf, args.file)
    end,
  })
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "jira-oil://all")
  vim.api.nvim_set_current_buf(buf)
  local calls, confirmations = {}, {}
  local response = 1
  local ok, err = pcall(function()
    h.stub(scratch, "drafts", {}, function()
      h.stub(cli, "get_filtered_issues", function(section, filters, cb)
        calls[#calls + 1] = { section = section, filters = vim.deepcopy(filters) }
        cb({
          {
            key = section == "sprint" and "PROJ-1" or "PROJ-2",
            fields = { status = { name = "Open" }, summary = "Original", assignee = { displayName = "A" } },
          },
        })
      end, function()
        h.stub(vim.fn, "confirm", function(message, choices, default)
          confirmations[#confirmations + 1] = { message = message, choices = choices, default = default }
          return response
        end, function()
          view.open(buf, "jira-oil://all")
          vim.api.nvim_win_set_cursor(0, { 2, 0 })
          fn(buf, calls, confirmations, function(value)
            response = value
          end)
        end)
      end)
    end)
  end)
  vim.api.nvim_set_current_buf(previous)
  vim.api.nvim_del_augroup_by_id(group)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if not initial_buffers[candidate] then
      view.cache[candidate], view.open_seq[candidate], view.mark_keys[candidate] = nil, nil, nil
      vim.api.nvim_buf_delete(candidate, { force = true })
    end
  end
  if not ok then
    error(err, 0)
  end
end

local function edit(buf)
  local line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
  local first, last = line:find("Original", 1, true)
  vim.api.nvim_buf_set_text(buf, 1, first - 1, 1, last, { "Pending" })
end

local function snapshot(buf)
  return {
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    modified = vim.bo[buf].modified,
    cache = vim.deepcopy(view.cache[buf]),
    keys = view.get_all_line_keys(buf),
    copies = view.get_all_copy_sources(buf),
    drafts = vim.deepcopy(scratch.drafts),
    sequence = view.open_seq[buf],
    cursor = vim.api.nvim_win_get_cursor(0),
  }
end

local operations = {
  refresh = function(buf)
    view.refresh(buf)
  end,
  reload = function(buf)
    view.open(buf, "jira-oil://all")
  end,
  same_uri = function()
    jira.open("all")
  end,
  close = function(buf)
    actions.close.callback({ buf = buf })
  end,
  reset = function(buf)
    actions.reset.callback({ buf = buf })
  end,
  assignee = function(buf)
    actions.filter_by_assignee.callback({ buf = buf })
  end,
  status = function(buf)
    actions.filter_by_status.callback({ buf = buf })
  end,
  project = function(buf)
    actions.filter_by_project.callback({ buf = buf })
  end,
  search = function(buf)
    h.stub(vim.ui, "input", function(_, cb)
      cb("Pending")
    end, function()
      actions.filter_prompt.callback({ buf = buf })
    end)
  end,
  clear_filters = function(buf)
    actions.clear_filters.callback({ buf = buf })
  end,
  parent = function(buf)
    actions.parent_view.callback({ buf = buf })
  end,
  open = function()
    jira.open("backlog")
  end,
}

local names = vim.tbl_keys(operations)
table.sort(names)
for _, name in ipairs(names) do
  for _, state in ipairs({ "text edits", "draft", "queued removal" }) do
    t.test("unsaved: cancelling " .. name .. " with " .. state .. " preserves all list state", function()
      with_list(function(buf, calls, confirmations)
        if state == "text edits" then
          edit(buf)
        else
          scratch.drafts["PROJ-1"] = {
            diff = state == "draft" and { summary_changed = true } or { queued_for_removal = true },
          }
          t.eq(vim.bo[buf].modified, false)
        end
        view.replace_all_copy_sources(buf, { [1] = "PROJ-9" })
        view.decorate_current(buf)
        local before = snapshot(buf)
        local cache_clears = 0
        h.stub(cli, "clear_cache", function()
          cache_clears = cache_clears + 1
        end, function()
          operations[name](buf)
        end)
        t.eq(vim.api.nvim_get_current_buf(), buf)
        t.eq(snapshot(buf), before)
        t.eq(#calls, 2, "cancelling must not fetch issues")
        t.eq(cache_clears, 0, "cancelling must not invalidate the CLI cache")
        t.eq(#confirmations, 1)
        t.eq(confirmations[1].default, 1, "keep editing must be the default")
      end)
    end)
  end
  t.test("unsaved: " .. name .. " never prompts for a clean list", function()
    with_list(function(buf, _, confirmations)
      scratch.drafts["OTHER-1"] = { diff = { queued_for_removal = true } }
      scratch.drafts["PROJ-1"] = { diff = { queued_for_removal = false } }
      operations[name](buf)
      t.eq(#confirmations, 0)
    end)
  end)
end

for _, response in ipairs({ 0, 2 }) do
  t.test("unsaved: refresh response " .. response .. " cancels or reloads", function()
    with_list(function(buf, calls, confirmations, answer)
      edit(buf)
      local before = snapshot(buf)
      answer(response)
      view.refresh(buf)
      t.eq(#confirmations, 1)
      if response == 0 then
        t.eq(snapshot(buf), before, "closing the prompt must cancel")
        t.eq(#calls, 2)
      else
        t.eq(#calls, 4)
        t.eq(vim.bo[buf].modified, false)
        t.ok(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find("Original", 1, true))
      end
    end)
  end)
end

t.test("unsaved: accepting close wipes the modified list", function()
  with_list(function(buf, _, confirmations, answer)
    edit(buf)
    answer(2)
    actions.close.callback({ buf = buf })
    t.eq(#confirmations, 1)
    t.eq(vim.api.nvim_buf_is_valid(buf), false)
  end)
end)

t.test("unsaved: accepting a filter changes the view once", function()
  with_list(function(buf, calls, confirmations, answer)
    edit(buf)
    local before = snapshot(buf)
    answer(2)
    actions.filter_by_status.callback({ buf = buf })
    t.eq(#confirmations, 1)
    t.ok(vim.api.nvim_get_current_buf() ~= buf)
    t.eq(view.get_spec(vim.api.nvim_get_current_buf()).filters.status, "Open")
    t.eq(#calls, 4)
    t.ok(vim.api.nvim_buf_is_valid(buf))
    t.eq(vim.bo[buf].bufhidden, "hide")
    t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before.lines)
    t.eq(vim.bo[buf].modified, true)
  end)
end)

for _, diff in ipairs({ { summary_changed = true }, { queued_for_removal = true } }) do
  t.test("unsaved: automatic refresh preserves stored drafts without prompting: " .. next(diff), function()
    with_list(function(buf, calls, confirmations)
      scratch.drafts["PROJ-1"] = { diff = diff }
      local drafts = vim.deepcopy(scratch.drafts)
      view.refresh(buf, { after_save = true })
      t.eq(#calls, 4)
      t.eq(#confirmations, 0)
      t.eq(scratch.drafts, drafts)
      t.eq(vim.bo[buf].modified, false)
    end)
  end)
end

t.test("unsaved: repeated opens during an initial load are clean and ignore stale responses", function()
  with_list(function(buf, _, confirmations)
    view.cache[buf] = nil
    local undolevels = vim.bo[buf].undolevels
    local pending = {}
    h.stub(cli, "get_filtered_issues", function(_, _, cb)
      pending[#pending + 1] = cb
    end, function()
      view.open(buf, "jira-oil://all")
      t.eq(vim.bo[buf].modified, false, "the loading message is not a user edit")
      local sequence = view.open_seq[buf]
      jira.open("all")
      t.eq(view.open_seq[buf], sequence + 1)
      t.eq(#confirmations, 0)
      t.eq(#pending, 2)
      pending[1]({})
      t.eq(#pending, 2, "the stale sprint response must not request backlog")
      pending[2]({})
      pending[3]({})
      t.eq(vim.bo[buf].modified, false)
      t.eq(vim.bo[buf].undolevels, undolevels, "restarting a load must restore the original undo setting")
      t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { view.header_sprint, view.header_backlog })
    end)
  end)
end)

t.test("unsaved: drafts on deleted rows are still protected", function()
  with_list(function(buf, calls, confirmations)
    scratch.drafts["PROJ-1"] = { diff = { queued_for_removal = true } }
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    view.replace_all_line_keys(buf, { [2] = "PROJ-2" })
    vim.bo[buf].modified = false
    local before = snapshot(buf)
    view.refresh(buf)
    t.eq(#confirmations, 1)
    t.eq(#calls, 2)
    t.eq(snapshot(buf), before)
  end)
end)

t.test("unsaved: accepting reset clears only this list's drafts", function()
  with_list(function(buf, _, confirmations, answer)
    edit(buf)
    scratch.drafts["PROJ-1"] = { diff = { queued_for_removal = true } }
    scratch.drafts["OTHER-1"] = { diff = { summary_changed = true } }
    answer(2)
    actions.reset.callback({ buf = buf })
    t.eq(#confirmations, 1)
    t.eq(vim.bo[buf].modified, false)
    t.is_nil(scratch.drafts["PROJ-1"])
    t.ok(scratch.has_draft("OTHER-1"))
  end)
end)

t.test("unsaved: successful saves refresh through the real guard without prompting", function()
  with_list(function(buf, calls, confirmations)
    edit(buf)
    scratch.drafts["PROJ-1"] = { diff = { summary_changed = true }, parsed = { summary = "Pending" } }
    h.stub(cli, "exec", function(_, cb)
      cb("", "", 0)
    end, function()
      mutator.execute_mutations(buf, mutator.compute_diff(buf))
    end)
    t.eq(#calls, 4)
    t.eq(#confirmations, 0)
    t.eq(vim.bo[buf].modified, false)
    t.is_nil(scratch.drafts["PROJ-1"])
  end)
end)

for _, new_edits in ipairs({ false, true }) do
  t.test("unsaved: deferred create refresh protects new edits: " .. tostring(new_edits), function()
    with_list(function(buf, calls, confirmations)
      vim.api.nvim_buf_set_lines(
        buf,
        -1,
        -1,
        false,
        { parser.format_line({
          fields = { status = { name = "To Do" }, summary = "New issue" },
        }) }
      )
      local deferred
      h.stub(vim, "defer_fn", function(callback, delay)
        t.eq(delay, 1200)
        deferred = callback
      end, function()
        h.stub(cli, "exec", function(_, cb)
          cb("https://example.atlassian.net/browse/PROJ-99", "", 0)
        end, function()
          mutator.execute_mutations(buf, mutator.compute_diff(buf))
        end)
      end)
      t.eq(#calls, 4, "the initial save refresh should complete")
      t.eq(#confirmations, 0)
      t.ok(deferred ~= nil)
      if new_edits then
        edit(buf)
      else
        scratch.drafts["PROJ-1"] = { diff = { queued_for_removal = true } }
      end
      local before = snapshot(buf)
      deferred()
      t.eq(#confirmations, 0)
      if new_edits then
        t.eq(#calls, 4)
        t.eq(snapshot(buf), before)
      else
        t.eq(#calls, 6)
        t.eq(vim.bo[buf].modified, false)
        t.eq(scratch.drafts, before.drafts)
      end
    end)
  end)
end

t.test("unsaved: a deletion-only save restores rows without a discard prompt", function()
  with_list(function(buf, _, confirmations)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    h.stub(cli, "exec", function()
      error("a deletion-only save must not execute Jira commands")
    end, function()
      mutator.save(buf)
    end)
    t.eq(#confirmations, 0)
    t.eq(vim.bo[buf].modified, false)
    t.eq(view.get_key_at_line(buf, 1), "PROJ-1")
  end)
end)

t.test("unsaved: closing an issue buffer still captures its draft without prompting", function()
  with_list(function(_, _, confirmations)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf].jira_oil_kind = "issue"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Pending issue edit" })
    local captured
    h.stub(scratch, "capture_draft", function(candidate)
      captured = candidate
    end, function()
      actions.close.callback({ buf = buf })
    end)
    t.eq(captured, buf)
    t.eq(#confirmations, 0)
    t.eq(vim.api.nvim_buf_is_valid(buf), false)
  end)
end)
