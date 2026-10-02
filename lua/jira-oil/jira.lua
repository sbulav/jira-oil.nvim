-- Semantic Jira operations. Future REST migration work extends this client;
-- callers do not construct HTTP requests or inspect curl/CLI output.
local rest = require("jira-oil.rest")
local M = {}

---Remove an issue from all active and future sprints, keeping closed history.
---@param key string
---@param callback fun(err: jira-oil.RestError|nil)
function M.move_to_backlog(key, callback)
  rest.request("POST", "/rest/agile/1.0/backlog/issue", { issues = { key } }, function(err, response)
    if err then
      callback(err)
    elseif response.status ~= 204 then
      callback({
        kind = "protocol",
        message = "Expected HTTP 204 for the backlog move; got HTTP " .. response.status .. ".",
      })
    else
      callback(nil)
    end
  end)
end

return M
