local config = require("jira-oil.config")
local util = require("jira-oil.util")

local M = {}

---Execute a Jira CLI command
---@param args table
---@param callback function(stdout, stderr, exit_code)
function M.exec(args, callback)
  local cmd = { config.options.cli.cmd }
  vim.list_extend(cmd, args)

  vim.system(cmd, { text = true, timeout = config.options.cli.timeout }, function(obj)
    vim.schedule(function()
      callback(obj.stdout, obj.stderr, obj.code)
    end)
  end)
end

---Execute a Jira CLI command synchronously
---@param args table
---@return string? stdout
---@return string? stderr
---@return number exit_code
function M.exec_sync(args)
  local cmd = { config.options.cli.cmd }
  vim.list_extend(cmd, args)

  local obj = vim.system(cmd, { text = true, timeout = config.options.cli.timeout }):wait()
  return obj.stdout, obj.stderr, obj.code
end

---Fetch active sprint ID
---@param callback function(id)
function M.get_active_sprint_id(callback)
  local args = { "sprint", "list", "--state", "active", "--raw" }
  if config.options.defaults.project ~= "" then
    table.insert(args, "-p")
    table.insert(args, config.options.defaults.project)
  end

  M.exec(args, function(stdout, stderr, code)
    if code ~= 0 or not stdout or stdout == "" then
      callback(nil)
      return
    end
    local lines = vim.split(stdout, "\n", { trimempty = true })
    if #lines > 1 then
      local parts = vim.split(lines[2], "\t")
      callback(parts[1])
    else
      callback(nil)
    end
  end)
end

---Fetch current sprint issues
---@param callback function(issues)
function M.get_sprint_issues(callback)
  M.exec({ "sprint", "list", "--current", "--raw" }, function(stdout, stderr, code)
    if code ~= 0 then
      vim.notify("Error fetching sprint issues: " .. (stderr or ""), vim.log.levels.ERROR)
      callback({})
      return
    end
    local issues = {}
    if stdout and stdout ~= "" then
      local ok, parsed = pcall(vim.json.decode, stdout)
      if ok and parsed and parsed.issues then
        issues = parsed.issues
      end
    end
    callback(issues)
  end)
end

---Fetch backlog issues
---@param callback function(issues)
function M.get_backlog_issues(callback)
  local args = { "issue", "list", "-q", "sprint is empty", "--raw" }
  if config.options.defaults.project ~= "" then
    table.insert(args, "-p")
    table.insert(args, config.options.defaults.project)
  end

  M.exec(args, function(stdout, stderr, code)
    if code ~= 0 then
      vim.notify("Error fetching backlog issues: " .. (stderr or ""), vim.log.levels.ERROR)
      callback({})
      return
    end
    local issues = {}
    if stdout and stdout ~= "" then
      local ok, parsed = pcall(vim.json.decode, stdout)
      if ok and parsed and parsed.issues then
        issues = parsed.issues
      end
    end
    callback(issues)
  end)
end

---Get an issue
---@param key string
---@param callback function(issue)
function M.get_issue(key, callback)
  M.exec({ "issue", "view", key, "--raw" }, function(stdout, stderr, code)
    if code ~= 0 then
      vim.notify("Error fetching issue: " .. (stderr or ""), vim.log.levels.ERROR)
      callback(nil)
      return
    end
    if stdout and stdout ~= "" then
      local ok, parsed = pcall(vim.json.decode, stdout)
      if ok then
        callback(parsed)
        return
      end
    end
    callback(nil)
  end)
end

return M
