local parser = require("jira-oil.parser")
local cli = require("jira-oil.cli")
local config = require("jira-oil.config")
local util = require("jira-oil.util")

local M = {}

---Diff buffer lines with original to compute mutations.
---Issue identity is resolved via inline virtual-text extmarks placed by
---view.lua, NOT by parsing the key from buffer text.
---@param buf number
---@return table[]
function M.compute_diff(buf)
  local view = require("jira-oil.view")
  local data = view.cache[buf]
  if not data then return {} end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local original = data.original
  local current = {}
  local mutations = {}

  local current_section = data.target == "backlog" and "backlog" or "sprint"
  local function is_header(line)
    return line == view.header_sprint or line == view.header_backlog
  end

  -- Build a row -> key mapping from extmarks (survives line moves)
  local row_to_key = view.get_all_line_keys(buf)
  local row_to_source = view.get_all_copy_sources(buf)
  local last_yank = view.last_yank

  local function source_from_last_yank(line)
    if not last_yank or not last_yank.entries then
      return nil
    end
    for _, entry in ipairs(last_yank.entries) do
      if entry.line == line and entry.source_key and entry.source_key ~= "" then
        return entry.source_key
      end
    end
    return nil
  end

  -- Track which keys we've already seen to handle duplicates
  local seen_keys = {}

  for lnum, line in ipairs(lines) do
    if line:match("%S") then
      if is_header(line) then
        -- Switch section based on which header we hit
        if line == view.header_backlog then
          current_section = "backlog"
        elseif line == view.header_sprint then
          current_section = "sprint"
        end
      else
        local parsed = parser.parse_line(line)
        if parsed then
          parsed.section = current_section

          -- Resolve identity from extmark, not from buffer text
          local key = row_to_key[lnum - 1] -- 0-indexed
          if key then
            parsed.key = key
            parsed.is_new = false
            parsed.row = lnum - 1
            -- Skip duplicate keys -- only the first occurrence counts
            if seen_keys[key] then
              vim.notify("Duplicate key " .. key .. " ignored.", vim.log.levels.WARN)
            else
              seen_keys[key] = true
              table.insert(current, parsed)
            end
          else
            parsed.is_new = true
            parsed.row = lnum - 1
            parsed.source_key = row_to_source[lnum - 1]
            if (not parsed.source_key or parsed.source_key == "") then
              parsed.source_key = source_from_last_yank(line)
            end
            -- Assign defaults for new issues
            if not parsed.type or parsed.type == "" then
              parsed.type = config.options.defaults.issue_type
            end
            if not parsed.assignee or parsed.assignee == "" then
              parsed.assignee = config.options.defaults.assignee
            end
            if not parsed.status or parsed.status == "" then
              parsed.status = "To Do"
            end
            table.insert(current, parsed)
          end
        end
      end
    end
  end

  -- Build lookup table for O(1) access
  local original_by_key = {}
  for _, item in ipairs(original) do
    original_by_key[item.key] = item
  end

  local current_by_key = {}
  for _, item in ipairs(current) do
    if not item.is_new and item.key and item.key ~= "" then
      current_by_key[item.key] = item
    end
  end

  for _, item in ipairs(current) do
    if item.is_new then
      table.insert(mutations, { type = "CREATE", item = item })
    else
      local orig = original_by_key[item.key]
      if orig then
        local updates = {}
        if orig.section and item.section and orig.section ~= item.section then
          local dest = item.section == "backlog" and "BACKLOG" or "SPRINT"
          table.insert(mutations, { type = "MOVE", key = item.key, dest = dest })
        end
        if item.status ~= orig.status then table.insert(updates, "status: " .. orig.status .. " -> " .. item.status) end
        if item.assignee ~= orig.assignee then table.insert(updates, "assignee: " .. orig.assignee .. " -> " .. item.assignee) end
        if item.summary ~= orig.summary then table.insert(updates, "summary: " .. orig.summary .. " -> " .. item.summary) end
        if #updates > 0 then
          table.insert(mutations, { type = "UPDATE", key = item.key, updates = updates, item = item })
        end
      end
    end
  end

  for _, item in ipairs(original) do
    if not current_by_key[item.key] then
      local from_section = item.section or data.target
      local dest = from_section == "sprint" and "BACKLOG" or "SPRINT"
      table.insert(mutations, { type = "MOVE", key = item.key, dest = dest })
    end
  end

  return mutations
end

---Save view and execute mutations
---@param buf number
function M.save(buf)
  local mutations = M.compute_diff(buf)
  if #mutations == 0 then
    vim.notify("No changes to apply.", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end

  local lines = { "Pending Mutations:" }
  for _, m in ipairs(mutations) do
    if m.type == "CREATE" then
      table.insert(lines, "[CREATE] New Task: " .. (m.item.summary or ""))
    elseif m.type == "UPDATE" then
      table.insert(lines, "[UPDATE] " .. m.key .. ": " .. table.concat(m.updates, ", "))
    elseif m.type == "MOVE" then
      table.insert(lines, "[MOVE] " .. m.key .. " to " .. m.dest)
    end
  end
  table.insert(lines, "")
  table.insert(lines, "Press 'Y' to confirm, 'n' to cancel.")

  local win_width = 80
  local win_height = #lines

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = win_width,
    height = win_height,
    col = math.floor((vim.o.columns - win_width) / 2),
    row = math.floor((vim.o.lines - win_height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Confirm Changes ",
  })
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_set_current_win(winnr)
      vim.api.nvim_set_current_buf(bufnr)
    end
  end)

  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"

  local function close()
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_win_close(winnr, true)
    end
  end

  vim.keymap.set("n", "Y", function()
    close()
    M.execute_mutations(buf, mutations)
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "n", function()
    close()
    vim.notify("Cancelled.", vim.log.levels.INFO)
  end, { buffer = bufnr, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    close()
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "q", function()
    close()
  end, { buffer = bufnr, silent = true })
end

---Execute computed mutations
---@param buf number
---@param mutations table[]
function M.execute_mutations(buf, mutations)
  local view = require("jira-oil.view")
  local data = view.cache[buf]
  local total = #mutations
  local done = 0
  local has_errors = false
  local has_create = false

  for _, m in ipairs(mutations) do
    if m.type == "CREATE" then
      has_create = true
      break
    end
  end

  local function check_done()
    done = done + 1
    if done >= total then
      if not has_errors then
        vim.notify("All changes applied successfully!", vim.log.levels.INFO)
      else
        vim.notify("Some changes failed. Check messages above.", vim.log.levels.WARN)
      end
      -- Always reset modified and refresh, even on partial failure
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
      end
      view.refresh(buf)
      if has_create then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(buf) then
            view.refresh(buf)
          end
        end, 1200)
      end
    end
  end

  local function apply_mutations(sprint_id)
    local function build_create_args(item, source_issue)
      local fields = source_issue and source_issue.fields or {}
      local source_project = fields and fields.project and fields.project.key or ""
      local project = source_project
      if project == "" then
        local source_from_key = util.issue_project_from_key(item.source_key)
        project = source_from_key or config.options.defaults.project
      end

      local source_type = ""
      if fields then
        local itype = fields.issuetype or fields.issueType
        source_type = itype and itype.name or ""
      end
      local issue_type = item.type ~= "" and item.type or source_type
      if issue_type == "" then
        issue_type = config.options.defaults.issue_type
      end

      local args = { "issue", "create", "-t", issue_type, "-s", item.summary, "--no-input" }

      if project ~= "" then
        table.insert(args, "-p")
        table.insert(args, project)
      end

      local assignee_input = item.assignee
      if assignee_input == "" and fields and fields.assignee then
        assignee_input = fields.assignee.displayName or fields.assignee.name or ""
      end
      local assignee = util.resolve_assignee_for_cli(assignee_input, fields and fields.assignee or nil)
      if assignee and assignee ~= "" then
        table.insert(args, "-a")
        table.insert(args, assignee)
      end

      local epic_key = ""
      if fields and fields.parent and fields.parent.key then
        epic_key = fields.parent.key
      elseif fields and config.options.epic_field and config.options.epic_field ~= "" then
        local raw = fields[config.options.epic_field]
        if type(raw) == "string" and raw ~= "" then
          epic_key = raw:match("([A-Z0-9]+%-%d+)") or ""
        end
      end
      if epic_key ~= "" then
        table.insert(args, "-P")
        table.insert(args, epic_key)
      end

      local components = {}
      if fields and type(fields.components) == "table" then
        for _, comp in ipairs(fields.components) do
          if comp and comp.name and comp.name ~= "" then
            table.insert(components, comp.name)
          end
        end
      end
      for _, comp in ipairs(components) do
        table.insert(args, "-C")
        table.insert(args, comp)
      end

      if fields and fields.description and fields.description ~= "" then
        table.insert(args, "--body")
        table.insert(args, fields.description)
      end

      return args
    end

    local function after_create_success(item, stdout, stderr)
      local key = util.extract_issue_key((stdout or "") .. "\n" .. (stderr or ""))
      if key and item.row ~= nil then
        view.set_line_key(buf, item.row, key)
        view.clear_copy_source_at_line(buf, item.row)
      end

      local status = item.status or ""
      if status ~= "" and status ~= "To Do" and status ~= config.options.defaults.status and key then
        cli.exec({ "issue", "move", key, status }, function(_, stderr, code)
          if code ~= 0 then
            vim.notify("Failed to set status for " .. key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
            has_errors = true
          end
          check_done()
        end)
      else
        check_done()
      end
    end

    for _, m in ipairs(mutations) do
      if m.type == "CREATE" then
        local function create_with_source(source_issue)
          local args = build_create_args(m.item, source_issue)
          cli.exec(args, function(stdout, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to create issue: " .. (stderr or ""), vim.log.levels.ERROR)
              has_errors = true
              check_done()
              return
            end
            after_create_success(m.item, stdout, stderr)
          end)
        end

        if m.item.source_key and m.item.source_key ~= "" then
          cli.get_issue(m.item.source_key, function(source_issue)
            if not source_issue then
              vim.notify("Could not load source issue " .. m.item.source_key .. ". Creating from list fields only.", vim.log.levels.WARN)
            end
            create_with_source(source_issue)
          end)
        else
          create_with_source(nil)
        end
      elseif m.type == "UPDATE" then
        local summary_changed = false
        local assignee_changed = false
        local status_changed = false
        for _, update in ipairs(m.updates) do
          if update:match("^summary:") then summary_changed = true end
          if update:match("^assignee:") then assignee_changed = true end
          if update:match("^status:") then status_changed = true end
        end

        -- Build sequential chain: summary -> assignee -> status
        -- Short-circuit on error to avoid inconsistent state
        local function do_status(skip_on_error)
          if skip_on_error or not status_changed then
            check_done()
            return
          end
          cli.exec({ "issue", "move", m.key, m.item.status }, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update status " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              has_errors = true
            end
            check_done()
          end)
        end

        local function do_assign(skip_on_error)
          if skip_on_error or not assignee_changed then
            do_status(skip_on_error)
            return
          end
          local assignee = m.item.assignee
          if assignee == "Unassigned" then assignee = "x" end
          cli.exec({ "issue", "assign", m.key, assignee }, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update assignee " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              has_errors = true
              do_status(true)
            else
              do_status(false)
            end
          end)
        end

        if summary_changed then
          local args = { "issue", "edit", m.key, "--no-input", "-s", m.item.summary }
          cli.exec(args, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update summary " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              has_errors = true
              do_assign(true)
            else
              do_assign(false)
            end
          end)
        else
          do_assign(false)
        end
      elseif m.type == "MOVE" then
        if m.dest == "SPRINT" then
          if sprint_id then
            cli.exec({ "sprint", "add", sprint_id, m.key }, function(stdout, stderr, code)
              if code ~= 0 then
                vim.notify("Failed to move to sprint " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
                has_errors = true
              end
              check_done()
            end)
          else
            vim.notify("Active sprint not found. Cannot move " .. m.key .. " to sprint.", vim.log.levels.WARN)
            has_errors = true
            check_done()
          end
        elseif m.dest == "BACKLOG" then
          vim.notify("Moving to Backlog (removing from Sprint) via jira-cli is not supported yet.", vim.log.levels.WARN)
          check_done()
        end
      end
    end
  end

  local needs_sprint_id = false
  for _, m in ipairs(mutations) do
    if m.type == "MOVE" and m.dest == "SPRINT" then
      needs_sprint_id = true
      break
    end
  end

  if needs_sprint_id then
    cli.get_active_sprint_id(function(sprint_id)
      apply_mutations(sprint_id)
    end)
  else
    apply_mutations(nil)
  end
end

return M
