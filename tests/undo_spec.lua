local t = require("minitest")
local view = require("jira-oil.view")
local scratch = require("jira-oil.scratch")
local cli = require("jira-oil.cli")
local h = require("helpers")
local util = require("jira-oil.util")

local function with_buffer(fn)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].undolevels = 321
  local ok, err = pcall(fn, buf)
  view.cache[buf], view.open_seq[buf], view.mark_keys[buf] = nil, nil, nil
  scratch.cache[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  if not ok then error(err) end
end

for _, target in ipairs({ "sprint", "all" }) do
  for _, newest_first in ipairs({ false, true }) do
    t.test("undo: overlapping " .. target .. " loads restore once, newest first=" .. tostring(newest_first), function()
      with_buffer(function(buf)
        local callbacks = {}
        h.stub(cli, "get_filtered_issues", function(_, _, cb) table.insert(callbacks, cb) end, function()
          view.open(buf, "jira-oil://" .. target)
          view.open(buf, "jira-oil://" .. target)
          t.eq(vim.bo[buf].undolevels, -1)
          local function complete(index)
            callbacks[index]({})
            if index == 2 and target == "all" then callbacks[3]({}) end
          end
          local first, second = newest_first and 2 or 1, newest_first and 1 or 2
          vim.defer_fn(function() complete(first) end, 5)
          t.ok(vim.wait(500, function() return vim.b[buf].jira_oil_undo_suspensions == 1 end))
          t.eq(vim.bo[buf].undolevels, -1, "a load is still pending")
          vim.defer_fn(function() complete(second) end, 5)
          t.ok(vim.wait(500, function() return vim.b[buf].jira_oil_undo_suspensions == nil end))
          t.eq(vim.bo[buf].undolevels, 321)
        end)
      end)
    end)
  end
end

t.test("undo: a single load restores the original setting", function()
  with_buffer(function(buf)
    h.stub(cli, "get_filtered_issues", function(_, _, cb) vim.defer_fn(function() cb({}) end, 5) end, function()
      view.open(buf, "jira-oil://sprint")
      t.ok(vim.wait(500, function() return vim.bo[buf].undolevels == 321 end))
    end)
  end)
end)

t.test("undo: a deleted buffer safely releases pending loads", function()
  with_buffer(function(buf)
    local callback
    h.stub(cli, "get_filtered_issues", function(_, _, cb) callback = cb end, function()
      view.open(buf, "jira-oil://sprint")
      vim.api.nvim_buf_delete(buf, { force = true })
      callback({})
    end)
  end)
end)

t.test("undo: list and issue rewrites preserve an outer suspension", function()
  with_buffer(function(buf)
    h.stub(cli, "get_filtered_issues", function(_, _, cb) cb({}) end, function()
      view.open(buf, "jira-oil://sprint")
    end)
    local release = util.suspend_undo(buf)
    view.reset(buf)
    t.eq(vim.bo[buf].undolevels, -1)
    scratch.open(buf, "jira-oil://issue/new")
    t.eq(vim.bo[buf].undolevels, -1)
    release()
    release()
    t.eq(vim.bo[buf].undolevels, 321)
  end)
end)
