local t = require("minitest")
local cli = require("jira-oil.cli")
local scratch = require("jira-oil.scratch")
local mutator = require("jira-oil.mutator")
local h = require("helpers")

-- An ADF description that flattens lossily (paragraph + bullet list).
local function adf_issue(key)
  return {
    key = key,
    fields = {
      summary = "S",
      issuetype = { name = "Task" },
      status = { name = "Open" },
      assignee = { displayName = "A" },
      description = {
        type = "doc",
        content = {
          { type = "paragraph", content = { { type = "text", text = "Hello" } } },
          {
            type = "bulletList",
            content = {
              {
                type = "listItem",
                content = { { type = "paragraph", content = { { type = "text", text = "item" } } } },
              },
            },
          },
        },
      },
    },
  }
end

---Open `key` in a fresh issue buffer with a stubbed fetch.
local function open_issue(key)
  local buf = vim.api.nvim_create_buf(true, false)
  h.stub(cli, "get_issue", function(k, cb)
    cb(adf_issue(k))
  end, function()
    scratch.open(buf, "jira-oil://issue/" .. key)
  end)
  return buf
end

---Rewrite the issue buffer's summary line (row 8) or description (row 10+).
local function set_summary(buf, text)
  vim.api.nvim_buf_set_lines(buf, 8, 9, false, { text })
end
local function set_description(buf, lines)
  vim.api.nvim_buf_set_lines(buf, 10, -1, false, lines)
end

local function has_description_update(mutations)
  for _, m in ipairs(mutations) do
    for _, u in ipairs(m.updates or {}) do
      if u:match("^description:") then
        return true
      end
    end
  end
  return false
end

t.test("description: opening an issue without edits creates no draft", function()
  scratch.clear_all_drafts()
  local buf = open_issue("PROJ-1")
  scratch.capture_draft(buf)
  t.is_nil(scratch.peek_draft("PROJ-1"))
end)

t.test("description: trailing whitespace alone is not an edit", function()
  scratch.clear_all_drafts()
  local buf = open_issue("PROJ-2")
  local lines = vim.api.nvim_buf_get_lines(buf, 10, -1, false)
  lines[#lines] = lines[#lines] .. "   "
  table.insert(lines, "")
  set_description(buf, lines)
  scratch.capture_draft(buf)
  t.is_nil(scratch.peek_draft("PROJ-2"))
end)

t.test("description: editing only the summary never sends the description", function()
  scratch.clear_all_drafts()
  local buf = open_issue("PROJ-3")
  set_summary(buf, "new summary")
  scratch.capture_draft(buf)
  local draft = scratch.peek_draft("PROJ-3")
  t.ok(draft ~= nil, "expected a summary draft")
  t.eq(draft.diff.summary_changed, true)
  t.eq(draft.diff.description_changed, false)

  local list = h.list_buf({ { key = "PROJ-3", summary = "S" } })
  local mutations = mutator.compute_diff(list)
  t.eq(#mutations, 1)
  t.eq(has_description_update(mutations), false)
end)

t.test("description: a real description edit is still sent", function()
  scratch.clear_all_drafts()
  local buf = open_issue("PROJ-4")
  set_description(buf, { "Rewritten" })
  scratch.capture_draft(buf)
  local draft = scratch.peek_draft("PROJ-4")
  t.ok(draft ~= nil, "expected a description draft")
  t.eq(draft.diff.description_changed, true)

  local list = h.list_buf({ { key = "PROJ-4", summary = "S" } })
  local mutations = mutator.compute_diff(list)
  t.eq(has_description_update(mutations), true)
  t.eq(mutations[1].item.description, "Rewritten")
end)

t.test("description: reopening an issue keeps its draft", function()
  scratch.clear_all_drafts()
  local buf = open_issue("PROJ-5")
  set_summary(buf, "draft summary")
  scratch.capture_draft(buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  local reopened = open_issue("PROJ-5")
  t.eq(vim.api.nvim_buf_get_lines(reopened, 8, 9, false)[1], "draft summary")
  scratch.capture_draft(reopened)
  local draft = scratch.peek_draft("PROJ-5")
  t.ok(draft ~= nil, "draft was dropped on reopen")
  t.eq(draft.diff.summary_changed, true)
  t.eq(draft.diff.description_changed, false)
end)
