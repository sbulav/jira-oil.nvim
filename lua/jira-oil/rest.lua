local config = require("jira-oil.config")
local sync = require("jira-oil.sync")

local M = {}

---@class jira-oil.RestError
---@field kind string
---@field message string
---@field status? number
---@field retryable? boolean

local function fail(callback, message)
  vim.schedule(function()
    callback({ kind = "configuration", message = message })
  end)
end

-- curl's config-file syntax is distinct from JSON and shell quoting.
local function quote(value)
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  value = value:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
  return '"' .. value .. '"'
end

local function redact(value, secrets)
  value = tostring(value or "")
  for _, secret in ipairs(secrets) do
    if secret ~= "" then
      value = value:gsub(secret:gsub("([^%w])", "%%%1"), "[REDACTED]")
    end
  end
  return vim.fn.strcharpart(value:gsub("%c", " "), 0, 600)
end

local status_messages = {
  [400] = "invalid request or issue state",
  [401] = "authentication failed; check the REST credentials and server URL",
  [403] = "permission denied; check issue permissions and the Jira Software license",
  [404] = "resource unavailable; check the server/context path and issue access",
  [429] = "rate limited; retry later",
}

local function http_error(status, body, secrets)
  local message = status_messages[status] or (status >= 500 and "Jira server error" or "unexpected HTTP response")
  local ok, decoded = pcall(vim.json.decode, body)
  local details = {}
  if ok and type(decoded) == "table" then
    for _, value in ipairs(type(decoded.errorMessages) == "table" and decoded.errorMessages or {}) do
      if type(value) == "string" then
        table.insert(details, value)
      end
    end
    for _, name in ipairs(vim.tbl_keys(type(decoded.errors) == "table" and decoded.errors or {})) do
      if type(decoded.errors[name]) == "string" then
        table.insert(details, decoded.errors[name])
      end
    end
  end
  if #details > 0 then
    message = message .. ": " .. table.concat(details, "; ")
  end
  return {
    kind = "http",
    status = status,
    message = "HTTP " .. status .. ": " .. redact(message, secrets),
    retryable = status == 429 or status >= 500,
  }
end

---Perform an asynchronous JSON request without automatic retries or redirects.
---Credentials go to curl on stdin, never in argv or diagnostic messages.
---@param method string
---@param path string Relative REST path beginning with /rest/
---@param body table|nil
---@param callback fun(err: jira-oil.RestError|nil, response: table|nil)
function M.request(method, path, body, callback)
  local opts = config.options.rest or {}
  local server = opts.server
  if not server or server == "" then
    server = vim.env.JIRA_SERVER or ""
  end
  local login = opts.login
  if not login or login == "" then
    login = vim.env.JIRA_LOGIN
    if not login or login == "" then
      login = vim.env.JIRA_USER or ""
    end
  end
  local auth_type = opts.auth_type
  if not auth_type or auth_type == "" then
    auth_type = vim.env.JIRA_AUTH_TYPE or "basic"
  end
  if auth_type == "" then
    auth_type = "basic"
  end

  if type(server) ~= "string" or not server:match("^https?://[^/]+") or server:find("[%s%c@?#]") then
    fail(callback, "Set rest.server (or JIRA_SERVER) to your Jira HTTP(S) base URL, including any context path.")
    return
  end
  if auth_type ~= "basic" and auth_type ~= "bearer" then
    fail(callback, "Unsupported rest.auth_type; this transport supports basic and bearer authentication.")
    return
  end
  if auth_type == "basic" and (type(login) ~= "string" or login == "" or login:find("[:%c]")) then
    fail(callback, "Basic REST authentication requires rest.login, JIRA_LOGIN, or JIRA_USER.")
    return
  end
  if
    type(path) ~= "string"
    or not path:match("^/rest/")
    or path:find("[%c#]")
    or type(method) ~= "string"
    or not method:match("^[A-Z]+$")
  then
    fail(callback, "Invalid REST method or path.")
    return
  end

  local token = opts.token
  if type(token) == "function" then
    local ok, value = pcall(token)
    if not ok then
      fail(callback, "The rest.token credential provider failed.")
      return
    end
    token = value
  elseif token == nil then
    token = vim.env.JIRA_API_TOKEN
  end
  if type(token) ~= "string" or token == "" or token:find("%c") then
    fail(callback, "REST credentials are missing or invalid; set JIRA_API_TOKEN or a rest.token provider.")
    return
  end

  local timeout = opts.timeout or 10000
  if type(timeout) ~= "number" or timeout <= 0 or timeout ~= timeout or timeout == math.huge then
    fail(callback, "rest.timeout must be a positive number of milliseconds.")
    return
  end
  local cmd = opts.cmd or "curl"
  if type(cmd) ~= "string" or cmd == "" then
    fail(callback, "rest.cmd must be the curl executable path.")
    return
  end

  local authorization, encoded = nil, ""
  if auth_type == "bearer" then
    authorization = "Bearer " .. token
  else
    encoded = vim.base64.encode(login .. ":" .. token)
    authorization = "Basic " .. encoded
  end
  local secrets = { authorization, encoded, token }
  local input = "header = " .. quote("Authorization: " .. authorization) .. "\n"
  if body ~= nil then
    local ok, json = pcall(vim.json.encode, body)
    if not ok then
      fail(callback, "REST request body could not be encoded as JSON.")
      return
    end
    input = input .. "data-binary = " .. quote(json) .. "\n"
  end
  local args = {
    cmd,
    "--disable",
    "--silent",
    "--show-error",
    "--globoff",
    "--proto",
    "=http,https",
    "--config",
    "-",
    "--max-time",
    tostring(timeout / 1000),
    "--request",
    method,
    "--header",
    "Accept: application/json",
    "--header",
    "Content-Type: application/json",
    "--write-out",
    "\n%{http_code}",
    "--url",
    server:gsub("/+$", "") .. path,
  }

  local end_sync = sync.begin()
  local completed = false
  local function finish(obj)
    if completed then
      return
    end
    completed = true
    vim.schedule(function()
      end_sync()
      if obj.spawn_error then
        callback({
          kind = "configuration",
          message = "Could not start curl; check rest.cmd and that curl is installed.",
        })
        return
      end
      if obj.code ~= 0 then
        local timed_out = obj.code == 28 or obj.code == 124
        local message = timed_out and "REST request timed out" or "REST transport failed"
        message = message
          .. ": "
          .. redact(obj.stderr, secrets)
          .. ". Remote state may have changed; check it before retrying."
        callback({ kind = timed_out and "timeout" or "transport", message = message, retryable = true })
        return
      end
      local response_body, status_text = (obj.stdout or ""):match("^(.*)\n(%d%d%d)$")
      local status = tonumber(status_text)
      if not status or status < 100 then
        callback({ kind = "protocol", message = "REST transport returned no valid HTTP status." })
      elseif status < 200 or status >= 300 then
        callback(http_error(status, response_body, secrets))
      else
        callback(nil, { status = status, body = response_body })
      end
    end)
  end

  local ok = pcall(vim.system, args, { text = true, stdin = input, timeout = timeout + 1000 }, finish)
  if not ok then
    -- A spawn error may include command/config data; do not echo it.
    finish({ spawn_error = true })
  end
end

return M
