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

  -- Clean up caches when buffers are wiped to prevent memory leaks
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    pattern = "jira-oil://*",
    callback = function(args)
      view.cache[args.buf] = nil
      scratch.cache[args.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    pattern = "jira-oil://issue/*",
    callback = function(args)
      scratch.capture_draft(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("TextYankPost", {
    group = group,
    pattern = "*",
    callback = function(args)
      require("jira-oil.actions").on_text_yank_post(args.buf)
    end,
  })

end

---Open a specific URI
---@param uri string
function M.open(uri)
  if not uri:match("^jira%-oil://") then
    uri = "jira-oil://" .. uri
  end
  vim.cmd.edit(uri)
end

return M
