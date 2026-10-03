local t = require("minitest")
local cli = require("jira-oil.cli")
local config = require("jira-oil.config")
local h = require("helpers")

t.test("cli: missing executable reports errors and balances sync events", function()
  local options = vim.deepcopy(config.options)
  options.cli.cmd = "definitely-not-jira"
  local events = {}
  local group = vim.api.nvim_create_augroup("JiraOilSpawnSpec", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "JiraOilSyncStart", "JiraOilSyncEnd" },
    callback = function(ev) table.insert(events, ev.match) end,
  })
  local ok, err = pcall(function()
    h.stub(config, "options", options, function()
      for _ = 1, 2 do
        local result
        cli.exec({ "issue", "list" }, function(stdout, stderr, code)
          result = { stderr = stderr, code = code }
          t.is_nil(stdout)
        end)
        t.ok(vim.wait(1000, function() return result ~= nil and #events % 2 == 0 end))
        t.ok(result.code ~= 0)
        t.ok(result.stderr:find("jira-cli not found", 1, true))
        t.ok(result.stderr:find("cli.cmd = definitely-not-jira", 1, true))
      end
      local stdout, stderr, code = cli.exec_sync({ "issue", "list" })
      t.is_nil(stdout)
      t.ok(code ~= 0)
      t.ok(stderr:find("jira-cli not found", 1, true))
    end)
    t.eq(events, { "JiraOilSyncStart", "JiraOilSyncEnd", "JiraOilSyncStart", "JiraOilSyncEnd" })
  end)
  vim.api.nvim_del_augroup_by_id(group)
  if not ok then error(err) end
end)
