local config = require("jira-oil.config")
local util = require("jira-oil.util")

local M = {}

local function parse_csv_line(line)
  local fields = {}
  local i = 1
  local len = #line
  while i <= len do
    local ch = line:sub(i, i)
    if ch == '"' then
      local j = i + 1
      local value = ""
      while j <= len do
        local c = line:sub(j, j)
        if c == '"' then
          if line:sub(j + 1, j + 1) == '"' then
            value = value .. '"'
            j = j + 2
          else
            j = j + 1
            break
          end
        else
          value = value .. c
          j = j + 1
        end
      end
      table.insert(fields, value)
      if line:sub(j, j) == "," then
        j = j + 1
      end
      i = j
    else
      local j = line:find(",", i, true) or (len + 1)
      table.insert(fields, line:sub(i, j - 1))
      i = j + 1
    end
  end
  return fields
end

local function parse_issue_csv(stdout)
  if not stdout or stdout == "" then
    return {}
  end
  local lines = vim.split(stdout, "\n", { trimempty = true })
  if #lines <= 1 then
    return {}
  end
  local header = parse_csv_line(lines[1])
  local issues = {}
  for i = 2, #lines do
    local row = parse_csv_line(lines[i])
    local issue = { fields = {} }
    for idx, col in ipairs(header) do
      local val = row[idx] or ""
      local name = col:lower()
      if name == "key" then
        issue.key = val
      elseif name == "status" then
        issue.fields.status = { name = val }
      elseif name == "type" then
        issue.fields.issueType = { name = val }
      elseif name == "assignee" then
        issue.fields.assignee = { displayName = val }
      elseif name == "summary" then
        issue.fields.summary = val
      elseif name == "labels" then
        issue.fields.labels = val
      end
    end
    table.insert(issues, issue)
  end
  return issues
end

local function build_jql(base)
  local parts = {}
  if base and base ~= "" then
    table.insert(parts, base)
  end
  if config.options.cli.issues.team_jql and config.options.cli.issues.team_jql ~= "" then
    table.insert(parts, config.options.cli.issues.team_jql)
  end
  if config.options.cli.issues.exclude_jql and config.options.cli.issues.exclude_jql ~= "" then
    table.insert(parts, config.options.cli.issues.exclude_jql)
  end
  if config.options.cli.issues.status_jql and config.options.cli.issues.status_jql ~= "" then
    table.insert(parts, config.options.cli.issues.status_jql)
  end
  return table.concat(parts, " AND ")
end

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
  local jql = build_jql("sprint in openSprints()")
  local args = { "issue", "list", "--csv", "--columns", table.concat(config.options.cli.issues.columns, ","), "-q", jql }
  if config.options.defaults.project ~= "" then
    table.insert(args, "-p")
    table.insert(args, config.options.defaults.project)
  end

  M.exec(args, function(stdout, stderr, code)
    if code ~= 0 then
      vim.notify("Error fetching sprint issues: " .. (stderr or ""), vim.log.levels.ERROR)
      callback({})
      return
    end
    callback(parse_issue_csv(stdout))
  end)
end

---Fetch backlog issues
---@param callback function(issues)
function M.get_backlog_issues(callback)
  local jql = build_jql("sprint IS EMPTY")
  local args = { "issue", "list", "--csv", "--columns", table.concat(config.options.cli.issues.columns, ","), "-q", jql }
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
    callback(parse_issue_csv(stdout))
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

---Fetch epics list for selection
---@param callback function(epics)
function M.get_epics(callback)
  local epic_cfg = config.options.cli.epics or {}
  local args = vim.deepcopy(epic_cfg.args or { "issue", "list", "--type", "Epic" })
  if epic_cfg.filters and #epic_cfg.filters > 0 then
    vim.list_extend(args, epic_cfg.filters)
  end
  if epic_cfg.order_by and epic_cfg.order_by ~= "" then
    vim.list_extend(args, { "--order-by", epic_cfg.order_by })
  end
  if epic_cfg.prefill_search and epic_cfg.prefill_search ~= "" then
    vim.list_extend(args, { "--query", epic_cfg.prefill_search })
  end
  local columns = epic_cfg.columns or { "key", "summary" }
  vim.list_extend(args, { "--csv", "--columns", table.concat(columns, ",") })

  M.exec(args, function(stdout, stderr, code)
    if code ~= 0 then
      vim.notify("Error fetching epics: " .. (stderr or ""), vim.log.levels.ERROR)
      callback({})
      return
    end
    local rows = parse_issue_csv(stdout)
    local epics = {}
    for _, issue in ipairs(rows) do
      local key = issue.key or ""
      local summary = issue.fields and issue.fields.summary or ""
      if key ~= "" then
        table.insert(epics, { key = key, summary = summary })
      end
    end
    callback(epics)
  end)
end

return M
