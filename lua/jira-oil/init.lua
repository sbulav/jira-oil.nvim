local config = require("jira-oil.config")
local view = require("jira-oil.view")
local scratch = require("jira-oil.scratch")

local M = {}

---@param opts? jira-oil.Config
function M.setup(opts)
  config.setup(opts)

  -- Register autocommands for the virtual filesystem
  local group = vim.api.nvim_create_augroup("JiraOil", { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "jira-oil://*",
    callback = function(args)
      local uri = args.file
      if uri:match("^jira%-oil://issue/") then
        scratch.open(args.buf, uri)
      else
        view.open(args.buf, uri)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "jira-oil://*",
    callback = function(args)
      local uri = args.file
      if uri:match("^jira%-oil://issue/") then
        scratch.save(args.buf)
      else
        require("jira-oil.mutator").save(args.buf)
      end
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("JiraOil", function(args)
    local target = args.args
    if target == "" then
      target = "all"
    end
    vim.cmd("edit jira-oil://" .. target)
  end, { nargs = "?", complete = function() return {"all", "sprint", "backlog"} end })
end

---Open a specific URI
---@param uri string
function M.open(uri)
  if not uri:match("^jira%-oil://") then
    uri = "jira-oil://" .. uri
  end
  vim.cmd("edit " .. uri)
end

return M
