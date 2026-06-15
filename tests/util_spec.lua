local t = require("minitest")
local util = require("jira-oil.util")

t.test("labels_to_list sorts and trims comma string", function()
  t.eq(util.labels_to_list(" b , a , c "), { "a", "b", "c" })
end)

t.test("labels_to_list accepts a table", function()
  t.eq(util.labels_to_list({ "z", "a" }), { "a", "z" })
end)

t.test("labels_to_list on empty/nil returns empty", function()
  t.eq(util.labels_to_list(nil), {})
  t.eq(util.labels_to_list(""), {})
end)

t.test("labels_to_string round-trips through normalization", function()
  t.eq(util.labels_to_string(" y, x "), "x, y")
end)

t.test("labels_to_set dedups", function()
  t.eq(util.labels_to_set({ "a", "a", "b" }), { a = true, b = true })
end)

t.test("issue_project_from_key extracts project", function()
  t.eq(util.issue_project_from_key("PROJ-123"), "PROJ")
  t.is_nil(util.issue_project_from_key("not-a-key"))
  t.is_nil(util.issue_project_from_key(nil))
end)

t.test("is_newtask_key detects placeholder keys", function()
  t.ok(util.is_newtask_key("PROJ-NEWTASK"))
  t.ok(not util.is_newtask_key("PROJ-12"))
end)

t.test("extract_issue_key finds key in CLI output", function()
  t.eq(util.extract_issue_key("Issue created\nPROJ-42 https://..."), "PROJ-42")
  t.is_nil(util.extract_issue_key("no key here"))
end)

t.test("extract_epic_key pulls key out of 'KEY: summary'", function()
  t.eq(util.extract_epic_key("EPIC-9: Build the thing"), "EPIC-9")
  t.eq(util.extract_epic_key(""), "")
end)

t.test("uri_encode/uri_decode round-trip reserved characters", function()
  local raw = "a b/c&d=e"
  t.eq(util.uri_decode(util.uri_encode(raw)), raw)
end)

t.test("resolve_assignee_for_cli: Unassigned and empty resolve to nil", function()
  t.is_nil(util.resolve_assignee_for_cli("Unassigned", nil))
  t.is_nil(util.resolve_assignee_for_cli("", nil))
end)

t.test("resolve_assignee_for_cli: bare token passes through", function()
  t.eq(util.resolve_assignee_for_cli("john.doe", nil), "john.doe")
end)

t.test("resolve_assignee_for_cli: explicit mapping notation wins", function()
  t.eq(util.resolve_assignee_for_cli("Full Name -> jdoe", nil), "jdoe")
end)

t.test("resolve_assignee_for_cli: display name resolves to source login", function()
  t.eq(util.resolve_assignee_for_cli("Alice", { name = "al", displayName = "Alice" }), "al")
end)
