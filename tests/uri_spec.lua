local t = require("minitest")
local view = require("jira-oil.view")

---Build a URI from a spec, parse it back, and assert target + filters survive.
local function round_trip(spec)
  local uri = view.build_uri(spec)
  local parsed, err = view.parse_uri(uri)
  t.ok(parsed ~= nil, "parse_uri failed for " .. uri .. ": " .. tostring(err))
  t.eq(parsed.target, spec.target, "target mismatch for " .. uri)
  t.eq(parsed.filters, spec.filters or {}, "filters mismatch for " .. uri)
  return uri
end

t.test("build_uri: bare targets", function()
  t.eq(view.build_uri({ target = "all" }), "jira-oil://all")
  t.eq(view.build_uri({ target = "sprint" }), "jira-oil://sprint")
  t.eq(view.build_uri({ target = "backlog" }), "jira-oil://backlog")
end)

t.test("build_uri: single path filter on the all view", function()
  t.eq(view.build_uri({ target = "all", filters = { assignee = "me" } }), "jira-oil://assignee/me")
end)

t.test("build_uri: single path filter keeps view query when not 'all'", function()
  t.eq(
    view.build_uri({ target = "sprint", filters = { project = "PROJ" } }),
    "jira-oil://project/PROJ?view=sprint"
  )
end)

t.test("round-trip: bare targets", function()
  round_trip({ target = "all", filters = {} })
  round_trip({ target = "sprint", filters = {} })
  round_trip({ target = "backlog", filters = {} })
end)

t.test("round-trip: single path filter", function()
  round_trip({ target = "all", filters = { assignee = "me" } })
  round_trip({ target = "sprint", filters = { project = "PROJ" } })
  round_trip({ target = "backlog", filters = { status = "In Progress" } })
end)

t.test("round-trip: multiple filters fall back to query form", function()
  round_trip({ target = "all", filters = { assignee = "me", status = "Open" } })
  round_trip({ target = "sprint", filters = { label = "infra", type = "Bug" } })
end)

t.test("round-trip: values needing encoding", function()
  round_trip({ target = "all", filters = { search = "fix login & logout" } })
end)

t.test("parse_uri: rejects unknown path", function()
  local parsed, err = view.parse_uri("jira-oil://bogus")
  t.is_nil(parsed)
  t.ok(err ~= nil)
end)

t.test("parse_uri: rejects non jira-oil URIs", function()
  local parsed = view.parse_uri("https://example.com")
  t.is_nil(parsed)
end)

t.test("parse_uri: derives parent_uri without filters", function()
  local parsed = view.parse_uri("jira-oil://assignee/me")
  t.eq(parsed.parent_uri, "jira-oil://all")
end)
