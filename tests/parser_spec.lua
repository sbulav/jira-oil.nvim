local t = require("minitest")
local parser = require("jira-oil.parser")

-- Default view columns are { status, assignee, summary }. The key is rendered
-- as virtual text and is NOT part of the editable buffer text, so parse_line
-- never sees it.

t.test("parse_line: blank line yields nil", function()
  t.is_nil(parser.parse_line("   "))
end)

t.test("parse_line: splits the three default columns", function()
  local parsed = parser.parse_line("To Do          │ Alice          │ Summary text")
  t.eq(parsed.status, "To Do")
  t.eq(parsed.assignee, "Alice")
  t.eq(parsed.summary, "Summary text")
end)

t.test("parse_line: rejoins a summary containing the column separator", function()
  local parsed = parser.parse_line("Done           │ Bob            │ a │ b │ c")
  t.eq(parsed.summary, "a │ b │ c")
end)

t.test("parse_line: strips a leading status icon", function()
  -- Status icon is a single multi-byte glyph followed by a space.
  local parsed = parser.parse_line("\u{f144} In Progress  │ Carol          │ Work")
  t.eq(parsed.status, "In Progress")
end)

t.test("format_line -> parse_line preserves editable fields", function()
  local issue = {
    key = "PROJ-1",
    fields = {
      status = { name = "To Do" },
      assignee = { displayName = "Dana" },
      summary = "Implement feature",
    },
  }
  local parsed = parser.parse_line(parser.format_line(issue))
  t.eq(parsed.status, "To Do")
  t.eq(parsed.assignee, "Dana")
  t.eq(parsed.summary, "Implement feature")
end)
