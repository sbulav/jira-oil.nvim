local t = require("minitest")
local view = require("jira-oil.view")
local mutator = require("jira-oil.mutator")
local h = require("helpers")

local function scratch_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y" })
  return buf
end

t.test("keys: a key longer than key_width reads back in full", function()
  local buf = scratch_buf()
  view.set_line_key(buf, 0, "PLATFORM-12345")
  t.eq(view.get_key_at_line(buf, 0), "PLATFORM-12345")
  t.eq(view.get_all_line_keys(buf), { [0] = "PLATFORM-12345" })
end)

t.test("keys: a key that fits reads back unchanged", function()
  local buf = scratch_buf()
  view.set_line_key(buf, 1, "AB-1")
  t.eq(view.get_key_at_line(buf, 1), "AB-1")
  t.is_nil(view.get_key_at_line(buf, 0))
end)

t.test("keys: set_line_key replaces the previous key on that row", function()
  local buf = scratch_buf()
  view.set_line_key(buf, 0, "OLD-1")
  view.set_line_key(buf, 0, "NEW-2")
  t.eq(view.get_key_at_line(buf, 0), "NEW-2")
end)

t.test("keys: replace_all_line_keys keeps full keys", function()
  local buf = scratch_buf()
  view.replace_all_line_keys(buf, { [0] = "PLATFORM-12345", [1] = "PLATFORM-67890" })
  t.eq(view.get_all_line_keys(buf), { [0] = "PLATFORM-12345", [1] = "PLATFORM-67890" })
end)

t.test("keys: compute_diff reports an edit on a long-key row under its full key", function()
  local buf = h.list_buf({ { key = "PLATFORM-12345", summary = "old summary" } })
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { (line:gsub("old summary", "new summary")) })
  local mutations = mutator.compute_diff(buf)
  t.eq(#mutations, 1)
  t.eq(mutations[1].type, "UPDATE")
  t.eq(mutations[1].key, "PLATFORM-12345")
end)
