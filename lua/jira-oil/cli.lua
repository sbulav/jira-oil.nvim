local config = require("jira-oil.config")
local util = require("jira-oil.util")

local M = {}

local response_cache = {}
local inflight = {}
local uv = vim.uv or vim.loop
local is_list = vim.islist or vim.tbl_islist

local function trim(s)
  return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function now_ms()
  return uv.now()
end

local function cache_enabled()
  local cache = config.options.cli.cache or {}
  return cache.enabled ~= false
end

local function cache_ttl_ms(name, fallback)
  local cache = config.options.cli.cache or {}
  local ttl = cache.ttl_ms or {}
  return ttl[name] or fallback
end

local function join_cmd(args)
  return table.concat(args, "\31")
end

local function exec_cached(cache_key, args, ttl_ms, callback)
  if cache_enabled() and ttl_ms and ttl_ms > 0 then
    local entry = response_cache[cache_key]
    if entry and entry.expires_at > now_ms() then
      vim.schedule(function()
        callback(entry.stdout, entry.stderr, entry.code)
      end)
      return
    end
  end

  if inflight[cache_key] then
    table.insert(inflight[cache_key], callback)
    return
  end
  inflight[cache_key] = { callback }

  M.exec(args, function(stdout, stderr, code)
    if cache_enabled() and ttl_ms and ttl_ms > 0 and code == 0 then
      response_cache[cache_key] = {
        stdout = stdout,
        stderr = stderr,
        code = code,
        expires_at = now_ms() + ttl_ms,
      }
    end

    local waiters = inflight[cache_key] or {}
    inflight[cache_key] = nil
    for _, cb in ipairs(waiters) do
      cb(stdout, stderr, code)
    end
  end)
end

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

local function parse_issue_json(stdout)
  if not stdout or trim(stdout) == "" then
    return {}, true
  end

  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, false
  end

  local rows = {}
  if type(decoded) == "table" then
    if is_list(decoded) then
      rows = decoded
    elseif type(decoded.issues) == "table" and is_list(decoded.issues) then
      rows = decoded.issues
    elseif type(decoded.values) == "table" and is_list(decoded.values) then
      rows = decoded.values
    elseif decoded.key then
      rows = { decoded }
    end
  end

  local issues = {}
  for _, raw in ipairs(rows) do
    local fields = raw.fields or raw
    local key = raw.key or fields.key or ""
    if key ~= "" then
      local status_name = ""
      if type(fields.status) == "table" then
        status_name = fields.status.name or ""
      elseif type(fields.status) == "string" then
        status_name = fields.status
      end

      local issue_type_name = ""
      local issue_type = fields.issuetype or fields.issueType or fields.type
      if type(issue_type) == "table" then
        issue_type_name = issue_type.name or ""
      elseif type(issue_type) == "string" then
        issue_type_name = issue_type
      end

      local assignee_name = ""
      if type(fields.assignee) == "table" then
        assignee_name = fields.assignee.displayName or fields.assignee.name or ""
      elseif type(fields.assignee) == "string" then
        assignee_name = fields.assignee
      end

      local labels = fields.labels
      if type(labels) == "table" then
        labels = table.concat(labels, ",")
      elseif type(labels) ~= "string" then
        labels = ""
      end

      table.insert(issues, {
        key = key,
        fields = {
          status = { name = status_name },
          issueType = { name = issue_type_name },
          assignee = { displayName = assignee_name },
          summary = fields.summary or "",
          description = fields.description or "",
          labels = labels,
          components = fields.components or {},
          parent = fields.parent,
        },
      })
    end
  end

  return issues, true
end

local function classify_error(stderr, code)
  local msg = trim(stderr)
  local lower = msg:lower()

  if lower:find("timed out", 1, true) or lower:find("deadline exceeded", 1, true) then
    return "request timed out; increase jira-oil cli.timeout or narrow your filters"
  end
  if lower:find("not found", 1, true) and lower:find("jira", 1, true) then
    return "jira CLI not found; install jira-cli and set require('jira-oil').setup({ cli = { cmd = 'jira' } })"
  end
  if lower:find("unauthorized", 1, true) or lower:find("authentication", 1, true) or lower:find("not logged", 1, true) or lower:find("401", 1, true) then
    return "authentication failed; run `jira init` and verify credentials"
  end
  if lower:find("forbidden", 1, true) or lower:find("permission", 1, true) or lower:find("403", 1, true) then
    return "permission denied; verify project permissions and issue access"
  end
  if code == 124 then
    return "request timed out; increase jira-oil cli.timeout"
  end
  return "jira command failed"
end

---@param action string
---@param stderr string|nil
---@param code number|nil
---@return string
function M.format_error(action, stderr, code)
  local raw = trim(stderr)
  local hint = classify_error(raw, code)
  if raw ~= "" then
    return string.format("%s (%s): %s", action, hint, raw)
  end
  return string.format("%s (%s)", action, hint)
end

---@param action string
---@param stderr string|nil
---@param code number|nil
function M.notify_error(action, stderr, code)
  vim.notify(M.format_error(action, stderr, code), vim.log.levels.ERROR)
end

local function list_issues_with_fallback(args_base, csv_columns, cache_scope, ttl_ms, callback)
  local raw_args = vim.deepcopy(args_base)
  table.insert(raw_args, "--raw")
  local raw_cache_key = cache_scope .. ":raw:" .. join_cmd(raw_args)

  exec_cached(raw_cache_key, raw_args, ttl_ms, function(stdout, stderr, code)
    if code == 0 then
      local parsed, ok = parse_issue_json(stdout)
      if ok then
        callback(parsed)
        return
      end
    end

    local csv_args = vim.deepcopy(args_base)
    vim.list_extend(csv_args, { "--csv", "--columns", table.concat(csv_columns, ",") })
    local csv_cache_key = cache_scope .. ":csv:" .. join_cmd(csv_args)

    exec_cached(csv_cache_key, csv_args, ttl_ms, function(csv_stdout, csv_stderr, csv_code)
      if csv_code ~= 0 then
        M.notify_error("Error fetching Jira issues", csv_stderr or stderr, csv_code)
        callback({})
        return
      end
      callback(parse_issue_csv(csv_stdout))
    end)
  end)
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

---@param scope string|nil
function M.clear_cache(scope)
  if not scope or scope == "all" then
    response_cache = {}
    inflight = {}
    return
  end

  for key, _ in pairs(response_cache) do
    if key:match("^" .. scope .. ":") then
      response_cache[key] = nil
    end
  end
  for key, _ in pairs(inflight) do
    if key:match("^" .. scope .. ":") then
      inflight[key] = nil
    end
  end
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
  local args = { "issue", "list", "-q", jql }
  if config.options.defaults.project ~= "" then
    table.insert(args, "-p")
    table.insert(args, config.options.defaults.project)
  end

  list_issues_with_fallback(args, config.options.cli.issues.columns, "sprint_issues", cache_ttl_ms("sprint_issues", 5000), callback)
end

---Fetch backlog issues
---@param callback function(issues)
function M.get_backlog_issues(callback)
  local jql = build_jql("sprint IS EMPTY")
  local args = { "issue", "list", "-q", jql }
  if config.options.defaults.project ~= "" then
    table.insert(args, "-p")
    table.insert(args, config.options.defaults.project)
  end

  list_issues_with_fallback(args, config.options.cli.issues.columns, "backlog_issues", cache_ttl_ms("backlog_issues", 5000), callback)
end

---Get an issue
---@param key string
---@param callback function(issue)
function M.get_issue(key, callback)
  local args = { "issue", "view", key, "--raw" }
  local cache_key = "issue:" .. key
  exec_cached(cache_key, args, cache_ttl_ms("issue", 15000), function(stdout, stderr, code)
    if code ~= 0 then
      M.notify_error("Error fetching issue", stderr, code)
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

  list_issues_with_fallback(args, columns, "epics", cache_ttl_ms("epics", 30000), function(rows)
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

M._parse_issue_json = parse_issue_json

return M
