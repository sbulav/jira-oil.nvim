-- One request counter for both CLI and REST transports.
local M = {}
local active_requests = 0

local function emit(event)
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = event, modeline = false })
  end)
end

---Begin a request and return an idempotent completion function.
---@return function
function M.begin()
  if active_requests == 0 then
    emit("JiraOilSyncStart")
  end
  active_requests = active_requests + 1
  local finished = false
  return function()
    if finished then
      return
    end
    finished = true
    active_requests = active_requests - 1
    if active_requests == 0 then
      emit("JiraOilSyncEnd")
    end
  end
end

return M
