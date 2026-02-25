local config = require("jira-oil.config")
local view = require("jira-oil.view")
local scratch = require("jira-oil.scratch")

local M = {}

---@param opts? jira-oil.Config
function M.setup(opts)
  config.setup(opts)

  -- Register autocommands for the virtual filesystem
  local group = vim.api.nvim_create_augroup("JiraOil", { clear = true })
  local draft_capture_seq = {}
  local list_decorate_seq = {}

  ---@param buf number
  local function capture_draft_debounced(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    draft_capture_seq[buf] = (draft_capture_seq[buf] or 0) + 1
    local seq = draft_capture_seq[buf]
    vim.defer_fn(function()
      if draft_capture_seq[buf] ~= seq then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.b[buf].jira_oil_kind ~= "issue" then
        return
      end
      scratch.capture_draft(buf)
    end, 150)
  end

  ---@param buf number
  local function decorate_list_debounced(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    list_decorate_seq[buf] = (list_decorate_seq[buf] or 0) + 1
    local seq = list_decorate_seq[buf]
    vim.defer_fn(function()
      if list_decorate_seq[buf] ~= seq then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.b[buf].jira_oil_kind ~= "list" then
        return
      end
      view.decorate_current(buf)
    end, 80)
  end

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
      draft_capture_seq[args.buf] = nil
      list_decorate_seq[args.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "jira-oil://*",
    callback = function(args)
      local kind = vim.b[args.buf].jira_oil_kind
      if kind == "issue" then
        capture_draft_debounced(args.buf)
      elseif kind == "list" then
        decorate_list_debounced(args.buf)
      end
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
