local t = require("minitest")
local h = require("helpers")
local actions = require("jira-oil.actions")
local cli = require("jira-oil.cli")
local mutator = require("jira-oil.mutator")
local scratch = require("jira-oil.scratch")
local view = require("jira-oil.view")

local function with_list(target, fn)
  local previous_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  local ok, err = pcall(function()
    h.stub(scratch, "drafts", {}, function()
      h.stub(cli, "get_filtered_issues", function(section, _, cb)
        cb({
          {
            key = section == "sprint" and "PROJ-1" or "PROJ-2",
            fields = { status = { name = "Open" }, summary = "Test issue" },
          },
        })
      end, function()
        view.open(buf, "jira-oil://" .. target)
      end)
      fn(buf)
    end)
  end)
  vim.api.nvim_set_current_buf(previous_buf)
  view.cache[buf], view.open_seq[buf], view.mark_keys[buf] = nil, nil, nil
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then
    error(err, 0)
  end
end

local function select_key(buf, key)
  for row, value in pairs(view.get_all_line_keys(buf)) do
    if value == key then
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      return row
    end
  end
  error("Fixture has no row for " .. key)
end

t.test("moves: unsupported backlog saves preserve the move and edits and stop later mutations", function()
  with_list("all", function(buf)
    select_key(buf, "PROJ-1")
    actions.move_to_backlog.callback()
    local row = select_key(buf, "PROJ-1")
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    local start_pos, end_pos = line:find("Test issue", 1, true)
    vim.api.nvim_buf_set_text(buf, row, start_pos - 1, row, end_pos, { "Pending edit" })
    local mutations = mutator.compute_diff(buf)
    t.eq(#mutations, 2)
    t.eq(mutations[1], { type = "MOVE", key = "PROJ-1", dest = "BACKLOG" })
    t.eq(mutations[2].type, "UPDATE")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local keys = view.get_all_line_keys(buf)
    local original = vim.deepcopy(view.cache[buf].original)
    local calls, refreshes, sprint_lookups, notices = 0, 0, 0, {}
    h.stub(cli, "exec", function(_, cb)
      calls = calls + 1
      cb("", "", 0)
    end, function()
      h.stub(cli, "get_active_sprint_id", function(cb)
        sprint_lookups = sprint_lookups + 1
        cb("42")
      end, function()
        h.stub(view, "refresh", function()
          refreshes = refreshes + 1
        end, function()
          h.stub(vim, "notify", function(message)
            notices[#notices + 1] = message
          end, function()
            mutator.execute_mutations(buf, mutations)
          end)
        end)
      end)
    end)
    t.eq(calls, 0, "the edit after an unsupported move must not run")
    t.eq(sprint_lookups, 0)
    t.eq(refreshes, 0)
    t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
    t.eq(view.get_all_line_keys(buf), keys)
    t.eq(view.cache[buf].original, original)
    t.eq(vim.bo[buf].modified, true)
    t.eq(mutator.compute_diff(buf), mutations, "the unapplied move and edit must remain queued")
    t.ok(notices[1]:find("not supported", 1, true))
    t.ok(notices[2]:find("Stopped at the first failure: 0 of 2 changes applied, 1 not attempted.", 1, true))
    for _, message in ipairs(notices) do
      t.ok(not message:find("All changes applied successfully!", 1, true))
    end
  end)
end)

for _, target in ipairs({ "sprint", "backlog" }) do
  for _, destination in ipairs({ "sprint", "backlog" }) do
    t.test("moves: " .. destination .. " action leaves a " .. target .. "-only view untouched", function()
      with_list(target, function(buf)
        select_key(buf, target == "sprint" and "PROJ-1" or "PROJ-2")
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local keys = view.get_all_line_keys(buf)
        local original = vim.deepcopy(view.cache[buf].original)
        local cursor = vim.api.nvim_win_get_cursor(0)
        for _, modified in ipairs({ false, true }) do
          vim.bo[buf].modified = modified
          local notice, level
          h.stub(vim, "notify", function(message, severity)
            notice, level = message, severity
          end, function()
            actions["move_to_" .. destination].callback()
          end)
          t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
          t.eq(view.get_all_line_keys(buf), keys)
          t.eq(view.cache[buf].original, original)
          t.eq(vim.api.nvim_win_get_cursor(0), cursor)
          t.eq(vim.bo[buf].modified, modified)
          t.eq(level, vim.log.levels.WARN)
          t.ok(notice:find("only available in jira-oil://all", 1, true))
        end
      end)
    end)
  end
end

t.test("moves: a supported sprint move still calls jira-cli and reports success", function()
  with_list("all", function(buf)
    select_key(buf, "PROJ-2")
    actions.move_to_sprint.callback()
    local calls, refreshes = {}, 0
    h.stub(cli, "get_active_sprint_id", function(cb)
      cb("42")
    end, function()
      h.stub(cli, "exec", function(args, cb)
        calls[#calls + 1] = args
        cb("", "", 0)
      end, function()
        h.stub(view, "refresh", function()
          refreshes = refreshes + 1
        end, function()
          mutator.execute_mutations(buf, mutator.compute_diff(buf))
        end)
      end)
    end)
    t.eq(calls, { { "sprint", "add", "42", "PROJ-2" } })
    t.eq(refreshes, 1)
    t.eq(vim.bo[buf].modified, false)
    t.eq(mutator.compute_diff(buf), {})
  end)
end)
