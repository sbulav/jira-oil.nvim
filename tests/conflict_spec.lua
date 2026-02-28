describe("jira-oil conflict detection", function()
  local conflict = require("jira-oil.conflict")

  it("detects assignee and status conflicts", function()
    local base = {
      summary = "Keep summary",
      description = "Same",
      assignee = "alice",
      status = "In Progress",
      components = { "API" },
    }
    local latest = {
      summary = "Keep summary",
      description = "Same",
      assignee = "bob",
      status = "Done",
      components = { "API" },
    }

    local has_conflict, fields = conflict.detect_conflicts(base, latest, { "assignee", "status" })
    assert.is_true(has_conflict)
    assert.are.same({ "assignee", "status" }, fields)
  end)

  it("normalizes component ordering", function()
    local base = conflict.snapshot_issue({
      fields = {
        components = { { name = "API" }, { name = "Backend" } },
      },
    })
    local latest = conflict.snapshot_issue({
      fields = {
        components = { { name = "Backend" }, { name = "API" } },
      },
    })

    local has_conflict, fields = conflict.detect_conflicts(base, latest, { "components" })
    assert.is_false(has_conflict)
    assert.are.same({}, fields)
  end)

  it("builds snapshots from issue payload", function()
    local snap = conflict.snapshot_issue({
      key = "PROJ-10",
      fields = {
        summary = "Summary",
        description = "Body",
        assignee = { displayName = "Alice" },
        status = { name = "Open" },
        issuetype = { name = "Task" },
        parent = { key = "PROJ-1" },
        components = { { name = "Backend" }, { name = "API" } },
      },
    })

    assert.are.equal("PROJ-10", snap.key)
    assert.are.equal("Summary", snap.summary)
    assert.are.equal("Body", snap.description)
    assert.are.equal("Alice", snap.assignee)
    assert.are.equal("Open", snap.status)
    assert.are.equal("Task", snap.issue_type)
    assert.are.equal("PROJ-1", snap.epic_key)
    assert.are.same({ "API", "Backend" }, snap.components)
  end)
end)
