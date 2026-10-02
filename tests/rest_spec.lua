local t = require("minitest")
local h = require("helpers")
local http = require("http_server")
local config = require("jira-oil.config")
local rest = require("jira-oil.rest")
local jira = require("jira-oil.jira")
local cli = require("jira-oil.cli")

local function with_rest(server, overrides, fn)
  local options = vim.deepcopy(config.options)
  options.rest = vim.tbl_extend("force", {
    cmd = "curl",
    server = server,
    login = "test@example.com",
    auth_type = "basic",
    token = function()
      return "test-token"
    end,
    timeout = 1500,
  }, overrides or {})
  h.stub(config, "options", options, fn)
end

local function await_request(start)
  local done, result, response
  start(function(err, value)
    result, response, done = err, value, true
  end)
  t.ok(
    vim.wait(5000, function()
      return done
    end, 10),
    "REST callback did not complete"
  )
  return result, response
end

local function with_sync_events(fn)
  local events = {}
  local group = vim.api.nvim_create_augroup("JiraOilRestTestSync", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "JiraOilSyncStart", "JiraOilSyncEnd" },
    callback = function(args)
      events[#events + 1] = args.match
    end,
  })
  local ok, err = pcall(fn, events)
  vim.api.nvim_del_augroup_by_id(group)
  if not ok then
    error(err, 0)
  end
end

t.test("REST: real curl sends a Basic-auth JSON backlog move with a context path", function()
  http.with_server({ status = 204 }, function(server)
    with_rest(server.url .. "/jira/", {}, function()
      local err = await_request(function(cb)
        jira.move_to_backlog("PROJ-123", cb)
      end)
      t.is_nil(err)
      t.eq(#server.requests, 1)
      local request = server.requests[1]
      t.eq(request.method, "POST")
      t.eq(request.path, "/jira/rest/agile/1.0/backlog/issue")
      t.eq(vim.json.decode(request.body), { issues = { "PROJ-123" } })
      t.eq(request.headers.authorization, "Basic " .. vim.base64.encode("test@example.com:test-token"))
      t.eq(request.headers["content-type"], "application/json")
    end)
  end)
end)

t.test("REST: bearer credentials with quotes/backslashes survive stdin config escaping", function()
  local token = 'test-"quoted"-\\token'
  http.with_server({ status = 204 }, function(server)
    with_rest(server.url, {
      auth_type = "bearer",
      login = "",
      token = function()
        return token
      end,
    }, function()
      local args
      local original_system = vim.system
      h.stub(vim, "system", function(cmd, opts, cb)
        args = cmd
        return original_system(cmd, opts, cb)
      end, function()
        local err = await_request(function(cb)
          jira.move_to_backlog("PROJ-1", cb)
        end)
        t.is_nil(err)
      end)
      t.eq(server.requests[1].headers.authorization, "Bearer " .. token)
      for _, arg in ipairs(args) do
        t.ok(not arg:find(token, 1, true), "token leaked into argv")
      end
    end)
  end)
end)

t.test("REST: environment defaults are resolved at request time", function()
  http.with_server({ status = 204 }, function(server)
    local options = vim.deepcopy(config.options)
    options.rest = { server = "", login = "", auth_type = "" }
    h.stub(vim.env, "JIRA_SERVER", server.url, function()
      h.stub(vim.env, "JIRA_LOGIN", "env@example.com", function()
        h.stub(vim.env, "JIRA_API_TOKEN", "env-token", function()
          h.stub(vim.env, "JIRA_AUTH_TYPE", "basic", function()
            h.stub(config, "options", options, function()
              t.is_nil(await_request(function(cb)
                jira.move_to_backlog("PROJ-1", cb)
              end))
              t.eq(server.requests[1].headers.authorization, "Basic " .. vim.base64.encode("env@example.com:env-token"))
            end)
          end)
        end)
      end)
    end)
  end)
end)

for _, legacy_login in ipairs({ false, "" }) do
  t.test("REST: JIRA_USER supplies the login when JIRA_LOGIN is " .. tostring(legacy_login), function()
    http.with_server({ status = 204 }, function(server)
      local options = vim.deepcopy(config.options)
      options.rest = { server = "", login = "", auth_type = "" }
      h.stub(config, "options", options, function()
        h.stub(vim.env, "JIRA_SERVER", server.url, function()
          h.stub(vim.env, "JIRA_LOGIN", legacy_login or nil, function()
            h.stub(vim.env, "JIRA_AUTH_TYPE", "basic", function()
              h.stub(vim.env, "JIRA_API_TOKEN", "env-token", function()
                for _, user in ipairs({ "first-user", "second-user" }) do
                  h.stub(vim.env, "JIRA_USER", user, function()
                    t.is_nil(await_request(function(cb)
                      jira.move_to_backlog("PROJ-1", cb)
                    end))
                    t.eq(
                      server.requests[#server.requests].headers.authorization,
                      "Basic " .. vim.base64.encode(user .. ":env-token")
                    )
                  end)
                end
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

t.test("REST: explicit login takes precedence over login environment aliases", function()
  http.with_server({ status = 204 }, function(server)
    h.stub(vim.env, "JIRA_USER", "user-env", function()
      h.stub(vim.env, "JIRA_LOGIN", "login-env", function()
        with_rest(server.url, {}, function()
          t.is_nil(await_request(function(cb)
            jira.move_to_backlog("PROJ-1", cb)
          end))
          t.eq(server.requests[1].headers.authorization, "Basic " .. vim.base64.encode("test@example.com:test-token"))
        end)
        with_rest(server.url, { login = "" }, function()
          t.is_nil(await_request(function(cb)
            jira.move_to_backlog("PROJ-1", cb)
          end))
          t.eq(server.requests[2].headers.authorization, "Basic " .. vim.base64.encode("login-env:test-token"))
        end)
      end)
    end)
  end)
end)

for _, status in ipairs({ 400, 401, 403, 404, 429, 500, 302 }) do
  t.test("REST: HTTP " .. status .. " fails without retries and balances sync events", function()
    http.with_server({
      status = status,
      body = '{"errorMessages":["test denial"]}',
      headers = status == 302 and { Location = "/redirect" } or nil,
    }, function(server)
      with_rest(server.url, {}, function()
        with_sync_events(function(events)
          local err = await_request(function(cb)
            jira.move_to_backlog("PROJ-1", cb)
          end)
          t.eq(err.kind, "http")
          t.eq(err.status, status)
          t.ok(err.message:find("test denial", 1, true))
          t.eq(err.retryable, status == 429 or status >= 500)
          t.eq(#server.requests, 1)
          t.ok(vim.wait(1000, function()
            return #events == 2
          end, 10))
          t.eq(events, { "JiraOilSyncStart", "JiraOilSyncEnd" })
        end)
      end)
    end)
  end)
end

t.test("REST: curl's default config cannot inject headers into Jira requests", function()
  local curl_home = vim.fn.tempname()
  vim.fn.mkdir(curl_home, "p")
  vim.fn.writefile({ 'header = "X-Injected: unwanted"' }, curl_home .. "/.curlrc")
  local ok, failure = pcall(function()
    h.stub(vim.env, "CURL_HOME", curl_home, function()
      http.with_server({ status = 204 }, function(server)
        with_rest(server.url, {}, function()
          t.is_nil(await_request(function(cb)
            jira.move_to_backlog("PROJ-1", cb)
          end))
          t.is_nil(server.requests[1].headers["x-injected"])
        end)
      end)
    end)
  end)
  vim.fn.delete(curl_home, "rf")
  if not ok then
    error(failure, 0)
  end
end)

t.test("REST: diagnostics redact both raw and encoded credentials", function()
  local authorization = "Basic " .. vim.base64.encode("test@example.com:test-token")
  local encoded = vim.base64.encode("test@example.com:test-token")
  http.with_server({
    status = 403,
    body = vim.json.encode({ errorMessages = { "Denied test-token " .. authorization .. " " .. encoded } }),
  }, function(server)
    with_rest(server.url, {}, function()
      local err = await_request(function(cb)
        jira.move_to_backlog("PROJ-1", cb)
      end)
      t.ok(not err.message:find("test-token", 1, true))
      t.ok(not err.message:find(authorization, 1, true))
      t.ok(not err.message:find(encoded, 1, true))
      t.ok(err.message:find("[REDACTED]", 1, true))
    end)
  end)
end)

t.test("REST: provider exceptions and missing credentials never reach curl", function()
  local calls = 0
  h.stub(vim, "system", function()
    calls = calls + 1
  end, function()
    for _, provider in ipairs({
      function()
        error("sensitive provider data")
      end,
      function()
        return nil
      end,
      function()
        return "injected\nheader"
      end,
    }) do
      with_rest("https://jira.example.com", { token = provider }, function()
        local err = await_request(function(cb)
          jira.move_to_backlog("PROJ-1", cb)
        end)
        t.eq(err.kind, "configuration")
        t.ok(not err.message:find("sensitive provider data", 1, true))
      end)
    end
  end)
  t.eq(calls, 0)
end)

t.test("REST: unsupported auth and invalid URLs fail before any process starts", function()
  local calls = 0
  h.stub(vim, "system", function()
    calls = calls + 1
  end, function()
    for _, overrides in ipairs({
      { auth_type = "mtls" },
      { auth_type = "cf-access" },
      { server = "file:///tmp/jira" },
      { server = "https://user:password@jira.example.com" },
      { server = "https://jira.example.com?wrong=true" },
      { login = "" },
      { timeout = 0 },
    }) do
      with_rest("https://jira.example.com", overrides, function()
        h.stub(vim.env, "JIRA_LOGIN", nil, function()
          h.stub(vim.env, "JIRA_USER", nil, function()
            local err = await_request(function(cb)
              jira.move_to_backlog("PROJ-1", cb)
            end)
            t.eq(err.kind, "configuration")
          end)
        end)
      end)
    end
  end)
  t.eq(calls, 0)
end)

t.test("REST: an unexpected successful status is not accepted as a backlog move", function()
  http.with_server({ status = 200, body = "login page" }, function(server)
    with_rest(server.url, {}, function()
      local err = await_request(function(cb)
        jira.move_to_backlog("PROJ-1", cb)
      end)
      t.eq(err.kind, "protocol")
    end)
  end)
end)

t.test("REST: timeouts preserve uncertainty and complete sync tracking", function()
  http.with_server(false, function(server)
    with_rest(server.url, { timeout = 80 }, function()
      with_sync_events(function(events)
        local err = await_request(function(cb)
          jira.move_to_backlog("PROJ-1", cb)
        end)
        t.eq(err.kind, "timeout")
        t.ok(err.message:find("Remote state may have changed", 1, true))
        t.ok(vim.wait(1000, function()
          return #events == 2
        end, 10))
        t.eq(events, { "JiraOilSyncStart", "JiraOilSyncEnd" })
      end)
    end)
  end)
end)

t.test("REST: a missing curl executable returns an error and balances sync events", function()
  with_rest("https://jira.example.com", { cmd = "/nonexistent/jira-oil-curl" }, function()
    with_sync_events(function(events)
      local err = await_request(function(cb)
        jira.move_to_backlog("PROJ-1", cb)
      end)
      t.ok(err ~= nil)
      t.eq(err.kind, "configuration")
      t.ok(not err.message:find("Remote state may have changed", 1, true))
      t.ok(err.message:find("Could not start curl", 1, true))
      t.ok(vim.wait(1000, function()
        return #events == 2
      end, 10))
      t.eq(events, { "JiraOilSyncStart", "JiraOilSyncEnd" })
    end)
  end)
end)

t.test("REST: transport failures redact credentials and leave remote state uncertain", function()
  with_rest("https://jira.example.com", {}, function()
    h.stub(vim, "system", function(_, _, cb)
      cb({ code = 7, stderr = "test-token " .. vim.base64.encode("test@example.com:test-token") })
    end, function()
      local err = await_request(function(cb)
        jira.move_to_backlog("PROJ-1", cb)
      end)
      t.eq(err.kind, "transport")
      t.ok(err.retryable)
      t.ok(not err.message:find("test-token", 1, true))
      t.ok(not err.message:find(vim.base64.encode("test@example.com:test-token"), 1, true))
      t.ok(err.message:find("Remote state may have changed", 1, true))
    end)
  end)
end)

t.test("sync: a CLI spawn failure returns an error and does not strand REST activity", function()
  with_rest("https://jira.example.com", {}, function()
    with_sync_events(function(events)
      h.stub(config.options.cli, "cmd", "/nonexistent/jira-oil-jira", function()
        local done, code, message
        cli.exec({ "issue", "list" }, function(_, stderr, exit_code)
          done, code, message = true, exit_code, stderr
        end)
        t.ok(vim.wait(1000, function()
          return done and #events == 2
        end, 10))
        t.eq(code, 1)
        t.ok(message:find("Could not start jira-cli", 1, true))
      end)
      h.stub(vim, "system", function(_, _, cb)
        cb({ code = 0, stdout = "\n204" })
      end, function()
        t.is_nil(await_request(function(cb)
          jira.move_to_backlog("PROJ-1", cb)
        end))
      end)
      t.ok(vim.wait(1000, function()
        return #events == 4
      end, 10))
      t.eq(events, { "JiraOilSyncStart", "JiraOilSyncEnd", "JiraOilSyncStart", "JiraOilSyncEnd" })
    end)
  end)
end)

t.test("sync: overlapping CLI and REST requests share a single activity interval", function()
  with_rest("https://jira.example.com", {}, function()
    with_sync_events(function(events)
      local completions, callbacks = {}, 0
      h.stub(vim, "system", function(_, _, cb)
        completions[#completions + 1] = cb
        return {}
      end, function()
        cli.exec({ "issue", "list" }, function()
          callbacks = callbacks + 1
        end)
        jira.move_to_backlog("PROJ-1", function(err)
          t.is_nil(err)
          callbacks = callbacks + 1
        end)
        t.ok(vim.wait(1000, function()
          return #events == 1
        end, 10))
        completions[1]({ code = 0, stdout = "", stderr = "" })
        t.ok(vim.wait(1000, function()
          return callbacks == 1
        end, 10))
        t.eq(events, { "JiraOilSyncStart" })
        completions[2]({ code = 0, stdout = "\n204", stderr = "" })
        t.ok(vim.wait(1000, function()
          return callbacks == 2 and #events == 2
        end, 10))
        t.eq(events, { "JiraOilSyncStart", "JiraOilSyncEnd" })
      end)
    end)
  end)
end)
