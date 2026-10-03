local t = require("minitest")
local h = require("helpers")
local config = require("jira-oil.config")
local custom = require("jira-oil.custom_fields")
local scratch = require("jira-oil.scratch")
local cli = require("jira-oil.cli")
local view = require("jira-oil.view")
local mutator = require("jira-oil.mutator")

local definitions = {
  { id = "customfield_10001", cli_name = "note", type = "text", label = "Note" },
  { id = "customfield_10002", cli_name = "points", type = "number", label = "Points" },
  { id = "customfield_10003", cli_name = "target-date", type = "date", label = "Target date" },
  { id = "customfield_10004", cli_name = "choice", type = "single_select", options = { "A", 'B, value="quoted"' } },
  { id = "customfield_10005", cli_name = "choices", type = "multi_select", options = { "Red", "Blue", "Green" } },
}

local function issue()
  return { key = "PROJ-1", fields = {
    summary = "S", issuetype = { name = "Task" }, status = { name = "Open" },
    assignee = { displayName = "A" }, project = { key = "PROJ" }, description = "Body",
    customfield_10001 = "hello\nthere", customfield_10002 = 3, customfield_10003 = "2026-01-01",
    customfield_10004 = { id = "10", value = "A" },
    customfield_10005 = { { id = "20", value = "Red" }, { id = "21", value = "Blue" } },
    customfield_19999 = { value = "Unselected" },
  } }
end

local function row(buf, name)
  return vim.api.nvim_buf_get_extmark_by_id(buf, scratch.ns_anchor, scratch.cache[buf].layout.anchors[name], {})[1]
end

local function set_field(buf, index, value)
  local defs = scratch.cache[buf].custom_field_defs
  local first = row(buf, "custom:" .. defs[index].id)
  local last = row(buf, defs[index + 1] and ("custom:" .. defs[index + 1].id) or "divider1")
  local end_line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1]
  vim.api.nvim_buf_set_text(buf, first, 0, last - 1, #end_line, vim.split(value, "\n", { plain = true }))
end

local function set_standard(buf, name, value)
  local first = row(buf, name)
  local text = vim.api.nvim_buf_get_lines(buf, first, first + 1, false)[1]
  vim.api.nvim_buf_set_text(buf, first, 0, first, #text, { value })
end

-- Decode the emitted RFC 4180 record to inspect actual alias/value pairs.
local function custom_args(args)
  local record
  for i, arg in ipairs(args) do if arg == "--custom" then record = args[i + 1] end end
  if not record then return {} end
  local fields, current, quoted, i = {}, "", false, 1
  while i <= #record do
    local ch = record:sub(i, i)
    if ch == '"' then
      if quoted and record:sub(i + 1, i + 1) == '"' then current = current .. '"'; i = i + 1
      else quoted = not quoted end
    elseif ch == "," and not quoted then table.insert(fields, current); current = ""
    else current = current .. ch end
    i = i + 1
  end
  t.ok(not quoted, "unbalanced CSV quoting")
  table.insert(fields, current)
  local values = {}
  for _, pair in ipairs(fields) do
    local name, value = pair:match("^([^=]+)=(.*)$")
    t.ok(name ~= nil, "invalid custom argument")
    values[name] = value
  end
  return values
end

local function with_custom(opts, fn)
  local saved_options, saved_drafts, saved_cache = config.options, scratch.drafts, scratch.cache
  local previous = vim.api.nvim_get_current_buf()
  config.setup(vim.tbl_deep_extend("force", {
    defaults = { project = "PROJ", assignee = "A" }, custom_fields = vim.deepcopy(definitions),
  }, opts or {}))
  scratch.drafts, scratch.cache = {}, {}
  local buffers = {}
  local function open(fetched, key)
    local buf = vim.api.nvim_create_buf(true, false)
    table.insert(buffers, buf)
    vim.api.nvim_set_current_buf(buf)
    h.stub(cli, "get_issue", function(_, cb) cb(vim.deepcopy(fetched or issue())) end, function()
      scratch.open(buf, "jira-oil://issue/" .. (key or "PROJ-1"))
    end)
    return buf
  end
  local function list()
    local buf = h.list_buf({ { key = "PROJ-1", summary = "S" } })
    table.insert(buffers, buf)
    return buf
  end
  local notices = {}
  local ok, err = pcall(function()
    h.stub(vim, "notify", function(message) table.insert(notices, message) end, function() fn(open, list, notices) end)
  end)
  for _, buf in ipairs(buffers) do
    view.cache[buf], view.mark_keys[buf] = nil, nil
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  config.options, scratch.drafts, scratch.cache = saved_options, saved_drafts, saved_cache
  vim.api.nvim_set_current_buf(previous)
  if not ok then error(err) end
end

local function with_commands(fail, fn)
  local commands = {}
  h.stub(cli, "exec", function(args, cb)
    table.insert(commands, vim.deepcopy(args))
    if fail and fail(args) then cb("", "failure", 1)
    elseif args[2] == "create" then cb("https://example.test/browse/PROJ-99", "", 0)
    else cb("", "", 0) end
  end, function()
    h.stub(view, "refresh", function() end, function()
      h.stub(vim, "defer_fn", function() end, fn)
    end)
  end)
  return commands
end

t.test("custom fields: selected values render with stable multiline anchors and no phantom edits", function()
  with_custom({}, function(open)
    local buf = open()
    t.eq(scratch.parse_buffer(buf).custom_fields, {
      customfield_10001 = "hello\nthere", customfield_10002 = "3", customfield_10003 = "2026-01-01",
      customfield_10004 = "A", customfield_10005 = "Red,Blue",
    })
    scratch.capture_draft(buf)
    t.is_nil(scratch.peek_draft("PROJ-1"))
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(calls, {})
    set_field(buf, 1, "first\nsecond\nthird\n")
    local parsed = scratch.parse_buffer(buf)
    t.eq(parsed.custom_fields.customfield_10001, "first\nsecond\nthird\n")
    t.eq(parsed.custom_fields.customfield_10002, "3")
    t.eq(parsed.summary, "S")
    t.eq(parsed.description, "Body")
  end)
end)

t.test("custom fields: all five types are updated before a status transition", function()
  with_custom({}, function(open)
    local buf = open()
    set_field(buf, 1, 'comma, equals= and "quotes"\nlast line')
    set_field(buf, 2, "4.50")
    set_field(buf, 3, "2028-02-29")
    set_field(buf, 4, 'B, value="quoted"')
    set_field(buf, 5, "Blue, Green")
    set_standard(buf, "status", "In Progress")
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(#calls, 2)
    t.eq(calls[1][2], "edit")
    t.eq(custom_args(calls[1]), {
      note = 'comma, equals= and "quotes"\nlast line', points = "4.5", ["target-date"] = "2028-02-29",
      choice = 'B, value="quoted"', choices = "-Red,Green",
    })
    t.eq(calls[2], { "issue", "move", "PROJ-1", "In Progress" })
    t.eq(scratch.cache[buf].original.fields.customfield_19999, { value = "Unselected" })
    t.ok(not scratch.has_draft("PROJ-1"))
    t.eq(with_commands(nil, function() scratch.save(buf) end), {})
  end)
end)

t.test("custom fields: creation sends all five types and records a clean baseline", function()
  with_custom({}, function(open)
    local buf = open(nil, "new")
    set_standard(buf, "summary", "New issue")
    set_field(buf, 1, 'text with a trailing "')
    set_field(buf, 2, "0")
    set_field(buf, 3, "2026-12-31")
    set_field(buf, 4, "A")
    set_field(buf, 5, "Green,Blue")
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(#calls, 1)
    t.eq(calls[1][2], "create")
    t.eq(custom_args(calls[1]), { note = 'text with a trailing "', points = "0", ["target-date"] = "2026-12-31", choice = "A", choices = "Blue,Green" })
    t.eq(scratch.cache[buf].key, "PROJ-99")
    t.ok(not scratch.cache[buf].is_new)
    t.eq(with_commands(nil, function() scratch.save(buf) end), {})
  end)
end)

t.test("custom fields: text and multi-select can be cleared", function()
  with_custom({}, function(open)
    local buf = open()
    set_field(buf, 1, "")
    set_field(buf, 5, "")
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(custom_args(calls[1]), { note = "", choices = "-Blue,-Red" })
    t.eq(scratch.cache[buf].original.fields.customfield_10005, {})
  end)
end)

for name, input in pairs({ number = { 2, "nan" }, hex = { 2, "0x10" }, invalid_date = { 3, "2025-02-29" },
  unknown_option = { 4, "C" }, empty_option = { 5, "Red,,Blue" }, clear_number = { 2, "" },
  clear_date = { 3, "" }, clear_select = { 4, "" } }) do
  t.test("custom fields: " .. name .. " is rejected before any command and remains a draft", function()
    with_custom({}, function(open, list, notices)
      local buf = open()
      set_field(buf, input[1], input[2])
      set_standard(buf, "status", "In Progress")
      t.eq(with_commands(nil, function() scratch.save(buf) end), {})
      t.ok(#notices > 0)
      t.ok(scratch.has_draft("PROJ-1"))
      t.ok(vim.bo[buf].modified)
      local list_buf = list()
      t.eq(with_commands(nil, function() mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf)) end), {})
    end)
  end)
end

t.test("custom fields: required blank values block creation", function()
  local defs = vim.deepcopy(definitions)
  defs[2].required = true
  with_custom({ custom_fields = defs }, function(open, _, notices)
    local buf = open(nil, "new")
    set_standard(buf, "summary", "New issue")
    t.eq(with_commands(nil, function() scratch.save(buf) end), {})
    t.ok(table.concat(notices):find("Points: value is required", 1, true))
    t.ok(scratch.cache[buf].is_new)
  end)
end)

t.test("custom fields: drafts survive closing and reopening the editor", function()
  with_custom({}, function(open)
    local buf = open()
    set_field(buf, 1, "draft text\nsecond line")
    set_field(buf, 2, "invalid number")
    scratch.capture_draft(buf)
    scratch.cache[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
    local reopened = open()
    t.eq(scratch.parse_buffer(reopened).custom_fields.customfield_10001, "draft text\nsecond line")
    t.eq(scratch.parse_buffer(reopened).custom_fields.customfield_10002, "invalid number")
    scratch.capture_draft(reopened)
    t.ok(scratch.has_draft("PROJ-1"))
  end)
end)

for _, through_list in ipairs({ false, true }) do
  t.test("custom fields: failed field edits stop status changes, list=" .. tostring(through_list), function()
    with_custom({}, function(open, list)
      local buf = open()
      set_field(buf, 5, "Green")
      set_standard(buf, "status", "In Progress")
      scratch.capture_draft(buf)
      local list_buf = through_list and list() or nil
      local calls = with_commands(function(args) return args[2] == "edit" end, function()
        if through_list then mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf)) else scratch.save(buf) end
      end)
      t.eq(#calls, 1)
      t.eq(calls[1][2], "edit")
      t.ok(scratch.has_draft("PROJ-1"))
      t.ok(vim.bo[buf].modified)
    end)
  end)
  t.test("custom fields: successful fields are not resent after a failed transition, list=" .. tostring(through_list), function()
    with_custom({}, function(open, list)
      local buf = open()
      set_field(buf, 5, "Blue,Green")
      set_standard(buf, "status", "In Progress")
      scratch.capture_draft(buf)
      local list_buf = through_list and list() or nil
      local function save()
        if through_list then mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf)) else scratch.save(buf) end
      end
      local calls = with_commands(function(args) return args[2] == "move" end, save)
      t.eq(#calls, 2)
      t.eq(custom_args(calls[1]), { choices = "-Red,Green" })
      t.ok(scratch.has_draft("PROJ-1"))
      t.eq(with_commands(nil, save), { { "issue", "move", "PROJ-1", "In Progress" } })
    end)
  end)
end

t.test("custom fields: list saves apply hidden issue-editor drafts", function()
  with_custom({}, function(open, list)
    local buf = open()
    set_field(buf, 2, "8")
    scratch.capture_draft(buf)
    scratch.cache[buf] = nil
    vim.api.nvim_buf_delete(buf, { force = true })
    local list_buf = list()
    local calls = with_commands(nil, function() mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf)) end)
    t.eq(#calls, 1)
    t.eq(custom_args(calls[1]), { points = "8" })
    t.ok(not scratch.has_draft("PROJ-1"))
  end)
end)

t.test("custom fields: multi-select order and numeric formatting alone are not edits", function()
  with_custom({}, function(open)
    local buf = open()
    set_field(buf, 2, "3.00")
    set_field(buf, 5, "Blue, Red, Blue")
    t.eq(with_commands(nil, function() scratch.save(buf) end), {})
    t.ok(not scratch.has_draft("PROJ-1"))
  end)
end)

t.test("custom fields: unsupported fetched shapes stay untouched and refuse editing", function()
  with_custom({}, function(open)
    local fetched = issue()
    fetched.fields.customfield_10001 = { type = "doc", content = {} }
    local buf = open(fetched)
    set_standard(buf, "summary", "changed")
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(#calls, 1)
    t.eq(custom_args(calls[1]), {})
    t.eq(scratch.cache[buf].original.fields.customfield_10001, fetched.fields.customfield_10001)
    set_field(buf, 1, "replace opaque value")
    t.eq(with_commands(nil, function() scratch.save(buf) end), {})
  end)
end)

t.test("custom fields: deleting a field block is rejected rather than clearing it", function()
  with_custom({}, function(open)
    local buf = open()
    local first, last = row(buf, "custom:customfield_10002"), row(buf, "custom:customfield_10003")
    vim.api.nvim_buf_set_lines(buf, first, last, false, {})
    t.eq(with_commands(nil, function() scratch.save(buf) end), {})
    t.ok(scratch.has_draft("PROJ-1"))
  end)
end)

t.test("custom fields: invalid or duplicate field definitions fail setup without replacing config", function()
  local saved = config.options
  for _, defs in ipairs({
    { { id = "wrong", cli_name = "note", type = "text" } },
    { { id = "customfield_10001", cli_name = "note", type = "user" } },
    { definitions[1], definitions[1] },
    { { id = "customfield_10001", cli_name = "note=other", type = "text" } },
  }) do
    t.ok(not pcall(config.setup, { custom_fields = defs }))
    t.eq(config.options, saved)
  end
end)

t.test("custom fields: definitions are captured for an already open editor", function()
  with_custom({}, function(open)
    local buf = open()
    set_field(buf, 2, "7")
    config.options.custom_fields = {}
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(custom_args(calls[1]), { points = "7" })
  end)
end)

t.test("custom fields: newer text entered during a save stays dirty", function()
  with_custom({}, function(open)
    local buf = open()
    set_field(buf, 1, "saved text")
    local callback
    h.stub(cli, "exec", function(_, cb) callback = cb end, function()
      scratch.save(buf)
      set_field(buf, 1, "newer text")
      callback("", "", 0)
    end)
    t.eq(scratch.cache[buf].original.fields.customfield_10001, "saved text")
    t.ok(vim.bo[buf].modified)
    t.eq(scratch.peek_draft("PROJ-1").parsed.custom_fields.customfield_10001, "newer text")
    t.eq(custom_args(with_commands(nil, function() scratch.save(buf) end)[1]), { note = "newer text" })
  end)
end)

t.test("custom fields: list creation copies only selected fields from its source", function()
  with_custom({}, function(_, list)
    local buf = list()
    local calls
    h.stub(cli, "get_issue", function(_, cb) cb(issue()) end, function()
      calls = with_commands(nil, function()
        mutator.execute_mutations(buf, { { type = "CREATE", item = {
          summary = "Copy", type = "Task", assignee = "A", status = "Open", source_key = "PROJ-1",
        } } })
      end)
    end)
    t.eq(#calls, 1)
    t.eq(custom_args(calls[1]), { note = "hello\nthere", points = "3", ["target-date"] = "2026-01-01", choice = "A", choices = "Blue,Red" })
  end)
end)

t.test("custom fields: list creation with missing required fields stops without creating", function()
  local defs = vim.deepcopy(definitions)
  defs[2].required = true
  with_custom({ custom_fields = defs }, function(_, list, notices)
    local buf = list()
    t.eq(with_commands(nil, function()
      mutator.execute_mutations(buf, { { type = "CREATE", item = { summary = "New", type = "Task", assignee = "A", status = "Open" } } })
    end), {})
    t.ok(table.concat(notices):find("Points: value is required", 1, true))
  end)
end)

t.test("custom fields: creation applies fields before a chosen status and retries only a failed move", function()
  with_custom({}, function(open)
    local buf = open(nil, "new")
    set_standard(buf, "summary", "New issue")
    set_standard(buf, "status", "In Progress")
    set_field(buf, 2, "5")
    local calls = with_commands(function(args) return args[2] == "move" end, function() scratch.save(buf) end)
    t.eq(#calls, 2)
    t.eq(calls[1][2], "create")
    t.eq(custom_args(calls[1]), { points = "5" })
    t.eq(calls[2], { "issue", "move", "PROJ-99", "In Progress" })
    t.ok(not scratch.cache[buf].is_new)
    t.ok(vim.bo[buf].modified)
    t.eq(with_commands(nil, function() scratch.save(buf) end), { { "issue", "move", "PROJ-99", "In Progress" } })
  end)
end)

t.test("custom fields: optional blanks are omitted from creation", function()
  with_custom({}, function(open)
    local buf = open(nil, "new")
    set_standard(buf, "summary", "New issue")
    local calls = with_commands(nil, function() scratch.save(buf) end)
    t.eq(#calls, 1)
    t.eq(custom_args(calls[1]), {})
    t.ok(not scratch.cache[buf].is_new)
  end)
end)

t.test("custom fields: a successful create without a readable key cannot be repeated", function()
  with_custom({}, function(open)
    local buf = open(nil, "new")
    set_standard(buf, "summary", "New issue")
    set_field(buf, 2, "5")
    local calls = 0
    h.stub(cli, "exec", function(_, cb) calls = calls + 1; cb("created", "", 0) end, function()
      scratch.save(buf)
      scratch.save(buf)
      scratch.reset(buf)
      scratch.save(buf)
    end)
    t.eq(calls, 1)
    t.ok(vim.bo[buf].modified)
  end)
end)

t.test("custom fields: newer multi-select edits survive an overlapping list save", function()
  with_custom({}, function(open, list)
    local buf = open()
    set_field(buf, 5, "Blue,Green")
    scratch.capture_draft(buf)
    local list_buf = list()
    local callback
    h.stub(view, "refresh", function() end, function()
      h.stub(cli, "exec", function(_, cb) callback = cb end, function()
        mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf))
        set_field(buf, 5, "Red")
        scratch.capture_draft(buf)
        callback("", "", 0)
      end)
    end)
    t.ok(scratch.has_draft("PROJ-1"))
    t.eq(scratch.peek_draft("PROJ-1").diff.custom_field_updates[1].previous, "Blue,Green")
    local calls = with_commands(nil, function() mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf)) end)
    t.eq(custom_args(calls[1]), { choices = "-Blue,-Green,Red" })
  end)
end)

t.test("custom fields: hidden newer edits rebase their multi-select delta after an overlapping save", function()
  with_custom({}, function(open, list)
    local buf = open()
    set_field(buf, 5, "Blue,Green")
    scratch.capture_draft(buf)
    local list_buf = list()
    local callback
    h.stub(view, "refresh", function() end, function()
      h.stub(cli, "exec", function(_, cb) callback = cb end, function()
        mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf))
        set_field(buf, 5, "Red")
        scratch.capture_draft(buf)
        scratch.cache[buf] = nil
        vim.api.nvim_buf_delete(buf, { force = true })
        callback("", "", 0)
      end)
    end)
    t.ok(scratch.has_draft("PROJ-1"))
    local calls = with_commands(nil, function() mutator.execute_mutations(list_buf, mutator.compute_diff(list_buf)) end)
    t.eq(custom_args(calls[1]), { choices = "-Blue,-Green,Red" })
  end)
end)
