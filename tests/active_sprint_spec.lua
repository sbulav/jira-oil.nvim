local t = require("minitest")
local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local fixture = root .. "/tests/fixtures/active-sprints.tsv"

local function with_fake(lines, exit_code, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines, dir .. "/response")
  local script = dir .. "/jira"
  vim.fn.writefile({
    "#!/bin/sh",
    'printf "%s\\n" "$@" > "$(dirname "$0")/args"',
    'cat "$(dirname "$0")/response"',
    "exit " .. (exit_code or 0),
  }, script)
  vim.fn.setfperm(script, "rwx------")
  local options = vim.deepcopy(config.options)
  options.cli.cmd = script
  options.defaults.project = "PROJ"
  local ok, err = pcall(function()
    h.stub(config, "options", options, function()
      local done, id = false, nil
      cli.get_active_sprint_id(function(result) id, done = result, true end)
      t.ok(vim.wait(1000, function() return done end), "sprint response timed out")
      fn(id, vim.fn.readfile(dir .. "/args"))
    end)
  end)
  vim.fn.delete(dir, "rf")
  if not ok then error(err) end
end

t.test("active sprint: recorded sanitized plain output returns a numeric ID without TUI flags", function()
  with_fake(vim.fn.readfile(fixture), 0, function(id, args)
    t.eq(id, 101)
    t.eq(args, { "sprint", "list", "--state", "active", "--table", "--plain", "--columns", "id,state", "-p", "PROJ" })
  end)
end)

for name, lines in pairs({
  empty = {},
  header_only = { "ID\tSTATE" },
  malformed = { "ID\tSTATE", "not-an-id\tactive" },
  inactive = { "ID\tSTATE", "101\tclosed" },
}) do
  t.test("active sprint: " .. name .. " returns nil", function()
    with_fake(lines, 0, function(id) t.is_nil(id) end)
  end)
end

t.test("active sprint: CLI failure returns nil even if stdout contains an ID", function()
  with_fake(vim.fn.readfile(fixture), 1, function(id) t.is_nil(id) end)
end)

t.test("active sprint: ignores invalid rows and handles padded CRLF output", function()
  with_fake({ "ID\tSTATE\r", "invalid\tactive\r", "  102\tactive  \r", "103\tactive\r" }, 0, function(id)
    t.eq(id, 102)
  end)
end)
