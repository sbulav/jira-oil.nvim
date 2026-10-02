local t = require("minitest")
local h = require("helpers")
local config = require("jira-oil.config")
local cli = require("jira-oil.cli")

local function with_env(values, fn)
  local names = { "JIRA_PROJECT_KEY", "JIRA_PROJECT", "JIRA_USER", "JIRA_ASSIGNEE" }
  local function next_var(i)
    if i > #names then
      fn()
    else
      local name = names[i]
      h.stub(vim.env, name, values[name], function()
        next_var(i + 1)
      end)
    end
  end
  h.stub(config, "options", vim.deepcopy(config.options), function()
    next_var(1)
  end)
end

t.test("config: environment-only setup uses JIRA_PROJECT_KEY for issue reads", function()
  with_env({ JIRA_PROJECT_KEY = "PROJ", JIRA_PROJECT = "LEGACY", JIRA_USER = "test-user" }, function()
    config.setup()
    t.eq(config.options.defaults.project, "PROJ")
    t.eq(config.options.defaults.assignee, "test-user")
    local args
    cli.clear_cache()
    h.stub(cli, "exec", function(argv, cb)
      args = argv
      cb("", "", 0)
    end, function()
      cli.get_filtered_issues("sprint", {}, function() end)
    end)
    t.eq(args[#args - 1], "-p")
    t.eq(args[#args], "PROJ")
  end)
end)

t.test("config: empty environment aliases fall back to legacy names at setup", function()
  with_env({ JIRA_PROJECT_KEY = "", JIRA_PROJECT = "LEGACY", JIRA_USER = "", JIRA_ASSIGNEE = "assignee" }, function()
    config.setup()
    t.eq(config.options.defaults.project, "LEGACY")
    t.eq(config.options.defaults.assignee, "assignee")
    h.stub(vim.env, "JIRA_PROJECT_KEY", "NEXT", function()
      config.setup()
      t.eq(config.options.defaults.project, "NEXT")
    end)
  end)
end)

t.test("config: explicit defaults override environment and absent variables stay empty", function()
  with_env({ JIRA_PROJECT_KEY = "ENV", JIRA_USER = "env-user" }, function()
    config.setup({ defaults = { project = "EXPLICIT", assignee = "explicit-user" } })
    t.eq(config.options.defaults.project, "EXPLICIT")
    t.eq(config.options.defaults.assignee, "explicit-user")
  end)
  with_env({}, function()
    config.setup()
    t.eq(config.options.defaults.project, "")
    t.eq(config.options.defaults.assignee, "")
  end)
end)
