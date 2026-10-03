local t = require("minitest")
local cli = require("jira-oil.cli")
local config = require("jira-oil.config")
local h = require("helpers")

local function with_fake(total, fail_second, fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/jira"
  vim.fn.writefile({
    "#!/bin/sh",
    'printf "call\\n" >> "$(dirname "$0")/calls"',
    'while [ "$#" -gt 0 ]; do',
    '  if [ "$1" = "--paginate" ]; then shift; page="$1"; fi',
    '  shift',
    'done',
    'case "$page" in 0:100) start=1;; 100:100) start=101;; 200:100) start=201;; *) exit 9;; esac',
    fail_second and '[ "$start" = 101 ] && { echo "page failed" >&2; exit 1; }' or ":",
    'echo "key,status,summary"',
    'end=$((start + 99))',
    'i=$start; while [ "$i" -le "$end" ] && [ "$i" -le ' .. total .. ' ]; do',
    '  echo "PROJ-$i,Open,Issue $i"; i=$((i + 1))',
    'done',
  }, script)
  vim.fn.setfperm(script, "rwx------")
  local options = vim.deepcopy(config.options)
  options.cli.cmd = script
  cli.clear_cache()
  local ok, err = pcall(function()
    h.stub(config, "options", options, function()
      fn(function() return #vim.fn.readfile(dir .. "/calls") end)
    end)
  end)
  cli.clear_cache()
  vim.fn.delete(dir, "rf")
  if not ok then error(err) end
end

local function fetch(scope)
  local result
  if scope == "sprint" then
    cli.get_sprint_issues(function(issues) result = issues end)
  else
    cli.get_filtered_issues("backlog", { assignee = "me" }, function(issues) result = issues end)
  end
  t.ok(vim.wait(3000, function() return result ~= nil end), "CLI response timed out")
  return result
end

for _, scope in ipairs({ "sprint", "filtered" }) do
  t.test("cli pagination: " .. scope .. " returns 130 unique issues and caches the joined result", function()
    with_fake(130, false, function(calls)
      local issues = fetch(scope)
      t.eq(#issues, 130)
      for i, issue in ipairs(issues) do t.eq(issue.key, "PROJ-" .. i) end
      t.eq(calls(), 2)
      t.eq(fetch(scope), issues)
      t.eq(calls(), 2)
    end)
  end)
end

t.test("cli pagination: a short list needs only one call", function()
  with_fake(30, false, function(calls)
    t.eq(#fetch("sprint"), 30)
    t.eq(calls(), 1)
  end)
end)

t.test("cli pagination: an exact full page requests an empty final page", function()
  with_fake(100, false, function(calls)
    t.eq(#fetch("sprint"), 100)
    t.eq(calls(), 2)
  end)
end)

t.test("cli pagination: a failed later page never caches a partial result", function()
  with_fake(130, true, function(calls)
    h.stub(vim, "notify", function() end, function()
      t.eq(fetch("sprint"), {})
      t.eq(fetch("sprint"), {})
    end)
    t.eq(calls(), 4)
  end)
end)
