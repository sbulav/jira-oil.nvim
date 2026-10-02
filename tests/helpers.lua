-- Shared fixtures for specs that drive list and issue buffers headlessly.
local parser = require("jira-oil.parser")
local view = require("jira-oil.view")

local M = {}

---Build a list buffer holding `issues` in the sprint section, wired up the
---way `view.open` leaves it: key extmarks plus `view.cache[buf].original`.
---@param issues table[] { key, status, assignee, summary }
---@return integer buf
function M.list_buf(issues)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.b[buf].jira_oil_kind = "list"
  local lines, original = {}, {}
  for _, it in ipairs(issues) do
    local line = parser.format_line({
      key = it.key,
      fields = {
        status = { name = it.status or "Open" },
        summary = it.summary or "",
        assignee = { displayName = it.assignee or "A" },
      },
    })
    table.insert(lines, line)
    local item = parser.parse_line(line)
    item.key = it.key
    item.section = "sprint"
    table.insert(original, item)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, it in ipairs(issues) do
    view.set_line_key(buf, i - 1, it.key)
  end
  view.cache[buf] = { original = original, copy_sources = {}, target = "sprint" }
  return buf
end

---Replace `module[name]` for the duration of `fn`.
function M.stub(module, name, replacement, fn)
  local saved = module[name]
  module[name] = replacement
  local ok, err = pcall(fn)
  module[name] = saved
  if not ok then
    error(err, 0)
  end
end

return M
