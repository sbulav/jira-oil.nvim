local t = require("minitest")
local h = require("helpers")
local jira_oil = require("jira-oil")
local cli = require("jira-oil.cli")
local config = require("jira-oil.config")
local scratch = require("jira-oil.scratch")

local function press(key)
  local callback = vim.fn.maparg(key, "n", false, true).callback
  t.ok(callback, "missing mapping for " .. key)
  callback()
end

local function field(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
end

local function edit_field(buf, row, text)
  vim.api.nvim_buf_set_text(buf, row, 0, row, #field(buf, row), { text })
end

local function pick_epic(buf)
  press("<C-e>")
  t.ok(vim.wait(500, function() return field(buf, 1) == "EPIC-2: New epic" end), "epic was not selected")
end

local function open_issue()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  press("<CR>")
  local buf = vim.api.nvim_get_current_buf()
  t.ok(vim.wait(500, function() return vim.fn.maparg("<C-e>", "n", false, true).buffer == 1 end), "issue did not load")
  return buf
end

local function preview_list_save(list)
  vim.api.nvim_set_current_buf(list)
  vim.cmd.write()
  t.ok(vim.wait(500, function() return vim.api.nvim_get_current_buf() ~= list end), "no confirmation")
  return field(0, 1)
end

local function wait_for_notice(jira, start, message)
  t.ok(vim.wait(500, function()
    for i = start + 1, #jira.messages do
      if jira.messages[i]:find(message, 1, true) then return true end
    end
    return false
  end), "save did not finish")
end

local function confirm_list_save(jira, list, message)
  local start = #jira.messages
  press("Y")
  wait_for_notice(jira, start, message or "All changes applied successfully!")
  t.eq(vim.api.nvim_get_current_buf(), list)
end

local function with_issue(test, epic, opts)
  local options, drafts = config.options, scratch.drafts
  local previous = vim.api.nvim_get_current_buf()
  local buffers = vim.api.nvim_list_bufs()
  local windows = vim.api.nvim_list_wins()
  local jira = {
    issue = {
      key = "EPIC-1",
      fields = {
        summary = "An issue",
        status = { name = "Open" },
        assignee = { displayName = "Alexandra Example-Tester", name = "atester" },
        issuetype = { name = "Task" },
        labels = { "certificates", "k8s", "prod" },
        components = { { name = "Original Component" } },
        description = "Original description",
        parent = epic and { key = epic } or nil,
      },
    },
    writes = {},
    messages = {},
  }
  scratch.drafts = {}
  jira_oil.setup(vim.tbl_deep_extend("force",
    { defaults = { project = "EPIC" }, cli = { cache = { enabled = false } } }, opts or {}))
  local ok, err = pcall(function()
    h.stub(vim, "system", function(args, _, on_exit)
      local stdout, stderr, code = "", "", 0
      if args[2] == "issue" and args[3] == "view" then
        stdout = vim.json.encode(jira.issue)
      elseif args[2] == "issue" and args[3] == "list" then
        if vim.list_contains(args, "--type") then
          stdout = "key,summary,status\nEPIC-2,New epic,Open\n"
        else
          stdout = ('key,assignee,status,summary,labels\nEPIC-1,%s,%s,An issue,"certificates, k8s, prod"\n')
            :format(jira.issue.fields.assignee.displayName, jira.issue.fields.status.name)
        end
      else
        table.insert(jira.writes, vim.list_slice(args, 2))
        if args[2] == "epic" and jira.before_epic_reply then jira.before_epic_reply() end
        if args[3] == "move" and jira.fail_move then
          stderr, code = "transition failed", 1
        elseif args[3] == "move" then
          jira.issue.fields.status.name = args[5]
        elseif args[2] == "epic" and args[3] == "add" and jira.fail_epic then
          stderr, code = "epic update failed", 1
        end
      end
      on_exit({ stdout = stdout, stderr = stderr, code = code })
    end, function()
      h.stub(vim.ui, "select", function(items, _, select) select(items[1]) end, function()
        h.stub(vim, "notify", function(message) table.insert(jira.messages, message) end, function()
          vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, false))
          jira_oil.open("sprint")
          local list = vim.api.nvim_get_current_buf()
          t.ok(vim.wait(500, function() return field(list, 1) ~= nil end), "list did not load")
          test(jira, list, open_issue())
        end)
      end)
    end)
  end)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.list_contains(windows, win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.api.nvim_set_current_buf(previous)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.list_contains(buffers, buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.api.nvim_del_augroup_by_name("JiraOil")
  config.options, scratch.drafts = options, drafts
  cli.clear_cache("all")
  if not ok then error(err, 0) end
end

t.test("epic: list save previews and applies only the selected epic", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: epic: (none) -> EPIC-2")
    confirm_list_save(jira, list)
    t.eq(jira.writes, { { "epic", "add", "EPIC-2", "EPIC-1" } })
    t.eq(vim.bo[issue].modified, false)
  end)
end)

t.test("epic: reopening the editor uses current Jira values for untouched fields", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    vim.api.nvim_set_current_buf(list)
    vim.api.nvim_buf_delete(issue, { force = true })
    jira.issue.fields.labels = { "new-server-label" }
    jira.issue.fields.description = "New description in Jira"
    local reopened = open_issue()
    t.eq({ field(reopened, 1), field(reopened, 4) }, { "EPIC-2: New epic", "new-server-label" })
    t.eq(field(reopened, 10), "New description in Jira")
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: epic: (none) -> EPIC-2")
  end)
end)

t.test("epic: list column widths cannot become changes to assignee or labels", function()
  with_issue(function(jira, list, issue)
    t.eq(field(issue, 6), jira.issue.fields.assignee.displayName)
    t.eq(field(issue, 4), "certificates, k8s, prod")
    pick_epic(issue)
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: epic: (none) -> EPIC-2")
    confirm_list_save(jira, list)
    t.eq(jira.writes, { { "epic", "add", "EPIC-2", "EPIC-1" } })
  end, nil, { view = { columns = {
    { name = "status", width = 15 }, { name = "assignee", width = 15 },
    { name = "summary" }, { name = "labels", width = 20 },
  } } })
end)

t.test("epic: saving a draft with real label edits removes and adds only the edited labels", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    edit_field(issue, 4, "k8s, prod, staging")
    t.eq(preview_list_save(list),
      "[UPDATE] EPIC-1: labels: certificates, k8s, prod -> k8s, prod, staging, epic: (none) -> EPIC-2")
    confirm_list_save(jira, list)
    t.eq(jira.writes, {
      { "epic", "add", "EPIC-2", "EPIC-1" },
      { "issue", "edit", "EPIC-1", "--no-input", "--label", "-certificates", "--label", "staging" },
    })
  end)
end)

t.test("epic: retrying a failed status change keeps the applied epic move", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    edit_field(issue, 5, "In Progress")
    jira.fail_move = true
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: status: Open -> In Progress, epic: EPIC-3 -> EPIC-2")
    confirm_list_save(jira, list, "Stopped at the first failure")

    jira.fail_move = false
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: status: Open -> In Progress")
    confirm_list_save(jira, list)
    t.eq(jira.writes, {
      { "epic", "add", "EPIC-2", "EPIC-1" },
      { "issue", "move", "EPIC-1", "In Progress" },
      { "issue", "move", "EPIC-1", "In Progress" },
    })
  end, "EPIC-3")
end)

t.test("epic: clearing the field removes the epic from the list save", function()
  with_issue(function(jira, list, issue)
    edit_field(issue, 1, "")
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: epic: EPIC-3 -> (none)")
    confirm_list_save(jira, list)
    t.eq(jira.writes, { { "epic", "remove", "EPIC-1" } })
  end, "EPIC-3")
end)

t.test("epic: list save applies component changes from a closed issue editor", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    edit_field(issue, 3, "New Component")
    press("<C-q>")
    t.eq(preview_list_save(list),
      "[UPDATE] EPIC-1: epic: (none) -> EPIC-2, components: Original Component -> New Component")
    confirm_list_save(jira, list)
    t.eq(jira.writes, {
      { "epic", "add", "EPIC-2", "EPIC-1" },
      { "issue", "edit", "EPIC-1", "--no-input", "--component", "-Original Component", "--component", "New Component" },
    })
  end)
end)

t.test("epic: retrying an issue-editor save skips the committed status transition", function()
  with_issue(function(jira, _, issue)
    pick_epic(issue)
    edit_field(issue, 5, "In Progress")
    jira.fail_epic = true
    vim.cmd.write()
    wait_for_notice(jira, 0, "Some updates failed")
    jira.fail_epic = false
    local start = #jira.messages
    vim.cmd.write()
    wait_for_notice(jira, start, "updated successfully")
    t.eq(jira.writes, {
      { "issue", "move", "EPIC-1", "In Progress" },
      { "epic", "add", "EPIC-2", "EPIC-1" },
      { "epic", "add", "EPIC-2", "EPIC-1" },
    })
  end)
end)

t.test("epic: existing issue type changes are rejected before either save writes", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    edit_field(issue, 2, "Bug")
    vim.cmd.write()
    wait_for_notice(jira, 0, "Change the issue type for EPIC-1 in Jira")
    t.ok(vim.bo[issue].modified)
    local start = #jira.messages
    vim.api.nvim_set_current_buf(list)
    vim.cmd.write()
    wait_for_notice(jira, start, "Change the issue type for EPIC-1 in Jira")
    t.eq(jira.writes, {})
  end)
end)

t.test("epic: list reset discards drafts in hidden issue editors", function()
  with_issue(function(_, list, issue)
    pick_epic(issue)
    vim.api.nvim_set_current_buf(list)
    h.stub(vim.fn, "confirm", function() return 2 end, function() press("gR") end)
    t.eq(open_issue(), issue)
    t.eq(field(issue, 1), "")
    t.eq(vim.bo[issue].modified, false)
    vim.api.nvim_set_current_buf(list)
    vim.cmd.write()
    t.eq(vim.api.nvim_get_current_buf(), list)
  end)
end)

t.test("epic: reverting the editor field during a list save keeps the newer choice", function()
  with_issue(function(jira, list, issue)
    pick_epic(issue)
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: epic: (none) -> EPIC-2")
    jira.before_epic_reply = function() edit_field(issue, 1, "") end
    confirm_list_save(jira, list)
    t.eq(preview_list_save(list), "[UPDATE] EPIC-1: epic: EPIC-2 -> (none)")
  end)
end)
