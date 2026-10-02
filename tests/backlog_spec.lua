local t = require("minitest")
local h = require("helpers")
local http = require("http_server")
local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local view = require("jira-oil.view")
local actions = require("jira-oil.actions")
local mutator = require("jira-oil.mutator")

local function with_list(server, second_in_backlog, fn)
  local options = vim.deepcopy(config.options)
  options.view.show_winbar = false
  options.rest = {
    server = server,
    login = "test@example.com",
    auth_type = "basic",
    token = function()
      return "test-token"
    end,
    timeout = 1500,
  }
  h.stub(config, "options", options, function()
    local previous_buf = vim.api.nvim_get_current_buf()
    local buf = h.list_buf({ { key = "PROJ-1", summary = "one" }, { key = "PROJ-2", summary = "two" } })
    local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local lines, keys
    if second_in_backlog then
      lines = { view.header_sprint, rows[1], view.header_backlog, rows[2] }
      keys = { [1] = "PROJ-1", [3] = "PROJ-2" }
      view.cache[buf].original[2].section = "backlog"
    else
      lines = { view.header_sprint, rows[1], rows[2], view.header_backlog }
      keys = { [1] = "PROJ-1", [2] = "PROJ-2" }
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    view.replace_all_line_keys(buf, keys)
    view.cache[buf].target = "all"
    view.cache[buf].uri = "jira-oil://all"
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.bo[buf].modified = false

    local notifications, refreshes, cli_calls = {}, 0, {}
    local ok, err = pcall(function()
      h.stub(vim, "notify", function(message)
        notifications[#notifications + 1] = message
      end, function()
        h.stub(view, "refresh", function()
          refreshes = refreshes + 1
        end, function()
          h.stub(cli, "exec", function(args, cb)
            cli_calls[#cli_calls + 1] = args
            cb("", "test failure", 1)
          end, function()
            fn(buf, notifications, function()
              return refreshes
            end, cli_calls)
          end)
        end)
      end)
    end)
    vim.api.nvim_set_current_buf(previous_buf)
    view.cache[buf], view.open_seq[buf], view.mark_keys[buf] = nil, nil, nil
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then
      error(err, 0)
    end
  end)
end

local function wait_for_failure(notifications)
  t.ok(
    vim.wait(5000, function()
      return (notifications[#notifications] or ""):find("Stopped at the first failure", 1, true) ~= nil
    end, 10),
    "save did not complete through the failure path"
  )
end

t.test("backlog: << queues a real REST move and refreshes only after success", function()
  http.with_server({ status = 204 }, function(server)
    with_list(server.url, false, function(buf, notifications, refreshes, cli_calls)
      actions.move_to_backlog.callback()
      t.eq(#server.requests, 0, "moving a row should wait for save")
      local mutations = mutator.compute_diff(buf)
      t.eq(#mutations, 1)
      t.eq(mutations[1], { type = "MOVE", key = "PROJ-1", dest = "BACKLOG" })
      h.stub(cli, "get_active_sprint_id", function()
        error("backlog moves do not need a sprint ID")
      end, function()
        mutator.execute_mutations(buf, mutations)
        t.ok(vim.wait(5000, function()
          return refreshes() == 1
        end, 10))
      end)
      t.eq(vim.json.decode(server.requests[1].body), { issues = { "PROJ-1" } })
      t.eq(view.cache[buf].original[1].section, "backlog")
      t.eq(#cli_calls, 0)
      t.ok(not vim.bo[buf].modified)
      t.eq(notifications[#notifications], "All changes applied successfully!")
      t.eq(mutator.compute_diff(buf), {})
    end)
  end)
end)

t.test("backlog: rejected REST moves keep edits, baseline, and retry intent", function()
  http.with_server({ status = 403 }, function(server)
    with_list(server.url, false, function(buf, notifications, refreshes, cli_calls)
      actions.move_to_backlog.callback()
      local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      mutator.execute_mutations(buf, mutator.compute_diff(buf))
      wait_for_failure(notifications)
      t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
      t.ok(vim.bo[buf].modified)
      t.eq(view.cache[buf].original[1].section, "sprint")
      t.eq(mutator.compute_diff(buf), { { type = "MOVE", key = "PROJ-1", dest = "BACKLOG" } })
      t.eq(refreshes(), 0)
      t.eq(#cli_calls, 0, "a failed REST write must not fall back to CLI")
      t.eq(#server.requests, 1)
      t.ok(notifications[1]:find("HTTP 403", 1, true))
    end)
  end)
end)

t.test("backlog: a successful move is not replayed when a later edit fails", function()
  http.with_server({ status = 204 }, function(server)
    with_list(server.url, true, function(buf, notifications, refreshes, cli_calls)
      actions.move_to_backlog.callback()
      local line = vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]
      local start, finish = line:find("two", 1, true)
      vim.api.nvim_buf_set_text(buf, 3, start - 1, 3, finish, { "TWO" })
      local mutations = mutator.compute_diff(buf)
      t.eq(mutations[1].type, "MOVE")
      t.eq(mutations[2].type, "UPDATE")
      mutator.execute_mutations(buf, mutations)
      wait_for_failure(notifications)
      t.eq(view.cache[buf].original[1].section, "backlog")
      t.eq(#server.requests, 1)
      t.eq(#cli_calls, 1)
      t.eq(refreshes(), 0)
      t.ok(vim.bo[buf].modified)

      local remaining = mutator.compute_diff(buf)
      t.eq(#remaining, 1)
      t.eq(remaining[1].type, "UPDATE")
      t.eq(remaining[1].key, "PROJ-2")
      h.stub(cli, "exec", function(_, cb)
        cb("", "", 0)
      end, function()
        mutator.execute_mutations(buf, remaining)
      end)
      t.eq(#server.requests, 1, "re-saving must not repeat the applied move")
      t.eq(refreshes(), 1)
    end)
  end)
end)

t.test("backlog: missing REST credentials fail the save without discarding the move", function()
  with_list("https://jira.example.com", false, function(buf, notifications, refreshes, cli_calls)
    h.stub(config.options.rest, "token", function()
      return nil
    end, function()
      actions.move_to_backlog.callback()
      mutator.execute_mutations(buf, mutator.compute_diff(buf))
      wait_for_failure(notifications)
    end)
    t.eq(refreshes(), 0)
    t.eq(#cli_calls, 0)
    t.ok(vim.bo[buf].modified)
    t.eq(view.cache[buf].original[1].section, "sprint")
    t.eq(mutator.compute_diff(buf)[1].dest, "BACKLOG")
  end)
end)

t.test("backlog: move actions leave single-section views untouched", function()
  with_list("https://jira.example.com", false, function(buf, notifications)
    for _, target in ipairs({ "sprint", "backlog" }) do
      view.cache[buf].target = target
      local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local keys = view.get_all_line_keys(buf)
      actions.move_to_backlog.callback()
      actions.move_to_sprint.callback()
      t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
      t.eq(view.get_all_line_keys(buf), keys)
      t.ok(not vim.bo[buf].modified)
      t.ok(notifications[#notifications]:find("only available in jira-oil://all", 1, true))
    end
  end)
end)

t.test("backlog: save confirmation explains removal from active and future sprints", function()
  with_list("https://jira.example.com", false, function(buf)
    actions.move_to_backlog.callback()
    mutator.save(buf)
    local win = vim.api.nvim_get_current_win()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.api.nvim_win_close(win, true)
    t.ok(table.concat(lines, "\n"):find("remove from active/future sprints", 1, true))
  end)
end)

t.test("backlog: read query allows closed history without admitting active or future membership", function()
  local options = vim.deepcopy(config.options)
  options.cli.cache.enabled = false
  options.cli.issues.team_jql = 'projectCategory = "Example"'
  options.cli.issues.status_jql = "resolution IS EMPTY"
  local command, issues
  h.stub(config, "options", options, function()
    h.stub(cli, "exec", function(args, cb)
      command = args
      cb("KEY,SUMMARY\nPROJ-1,Returned backlog issue\n", "", 0)
    end, function()
      cli.get_filtered_issues("backlog", { project = "PROJ", assignee = "me", label = "urgent" }, function(value)
        issues = value
      end)
    end)
  end)
  local jql
  for i, arg in ipairs(command) do
    if arg == "-q" then
      jql = command[i + 1]
    end
  end
  local clause = "(sprint IS EMPTY OR (sprint NOT IN openSprints() AND sprint NOT IN futureSprints()))"
  t.eq(jql:sub(1, #clause), clause, "OR must be grouped before the remaining filters")
  for _, filter in ipairs({
    'project = "PROJ"',
    "assignee = currentUser()",
    'labels = "urgent"',
    'projectCategory = "Example"',
    "resolution IS EMPTY",
  }) do
    t.ok(jql:find(filter, 1, true), "lost filter: " .. filter)
  end
  t.eq(issues[1].key, "PROJ-1")
end)
