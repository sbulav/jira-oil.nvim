describe("jira-oil cli json parsing", function()
  local cli = require("jira-oil.cli")

  it("parses issue list raw JSON with issues field", function()
    local payload = vim.json.encode({
      issues = {
        {
          key = "PROJ-1",
          fields = {
            summary = "Fix login",
            status = { name = "In Progress" },
            assignee = { displayName = "Alice" },
            issuetype = { name = "Bug" },
            labels = { "auth", "urgent" },
          },
        },
      },
    })

    local rows, ok = cli._parse_issue_json(payload)
    assert.is_true(ok)
    assert.are.equal(1, #rows)
    assert.are.equal("PROJ-1", rows[1].key)
    assert.are.equal("Fix login", rows[1].fields.summary)
    assert.are.equal("In Progress", rows[1].fields.status.name)
    assert.are.equal("Alice", rows[1].fields.assignee.displayName)
    assert.are.equal("Bug", rows[1].fields.issueType.name)
    assert.are.equal("auth,urgent", rows[1].fields.labels)
  end)

  it("returns parse failure for non-json text", function()
    local rows, ok = cli._parse_issue_json("not json")
    assert.is_nil(rows)
    assert.is_false(ok)
  end)
end)
