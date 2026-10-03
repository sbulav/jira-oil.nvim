local t = require("minitest")
local actions = require("jira-oil.actions")
local view = require("jira-oil.view")
local h = require("helpers")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function with_rows(fn)
  local previous = vim.api.nvim_get_current_buf()
  local register = vim.fn.getreginfo('"')
  local buf = h.list_buf({
    { key = "PROJ-1", summary = "first" },
    { key = "PROJ-2", summary = "second" },
    { key = "PROJ-3", summary = "third" },
    { key = "PROJ-4", summary = "fourth" },
  })
  vim.api.nvim_set_current_buf(buf)
  local setreg = vim.fn.setreg
  local ok, err = pcall(function()
    -- Exercise the real unnamed register without changing the OS clipboard.
    h.stub(vim.fn, "setreg", function(name, ...)
      if name == "+" then return 0 end
      return setreg(name, ...)
    end, function()
      h.stub(vim, "notify", function() end, fn)
    end)
  end)
  feed("<Esc>")
  setreg('"', register)
  vim.api.nvim_set_current_buf(previous)
  view.cache[buf], view.mark_keys[buf] = nil, nil
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err) end
end

for _, selection in ipairs({ "V", "v", "<C-v>" }) do
  for _, reversed in ipairs({ false, true }) do
    t.test("yank: current " .. selection .. " selection overrides old marks, reversed=" .. tostring(reversed), function()
      with_rows(function()
        feed("ggVj<Esc>")
        t.eq(vim.fn.getpos("'<")[2], 1)
        t.eq(vim.fn.getpos("'>")[2], 2)
        feed((reversed and "4G" or "3G") .. selection .. (reversed and "k" or "j"))
        t.ok(vim.fn.mode() == "V" or vim.fn.mode() == "v" or vim.fn.mode() == "\022")
        actions.yank_issue_key.callback()
        t.eq(vim.fn.getreg('"'), "PROJ-3\nPROJ-4")
      end)
    end)
  end
end

t.test("yank: normal mode still yanks only the current row", function()
  with_rows(function()
    feed("ggVj<Esc>3G")
    t.eq(vim.fn.mode(), "n")
    actions.yank_issue_key.callback()
    t.eq(vim.fn.getreg('"'), "PROJ-3")
  end)
end)
