local parser = require("jira-oil.parser")
local cli = require("jira-oil.cli")
local config = require("jira-oil.config")
local util = require("jira-oil.util")
local custom = require("jira-oil.custom_fields")

local M = {}
local saving = {}
local create_anchors = vim.api.nvim_create_namespace("JiraOilPendingCreate")

local function save_in_progress(buf)
  if not saving[buf] then return false end
  vim.notify("A Jira save is already in progress for this list.", vim.log.levels.WARN)
  return true
end

---Diff buffer lines with original to compute mutations.
---Issue identity is resolved via inline virtual-text extmarks placed by
---view.lua, NOT by parsing the key from buffer text.
---@param buf number
---@return table[]
function M.compute_diff(buf)
  local view = require("jira-oil.view")
  local scratch = require("jira-oil.scratch")
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
              parsed.status = config.options.defaults.status
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
        local draft = scratch.peek_draft(item.key)
        local draft_parsed = draft and draft.parsed or nil
        local draft_diff = (draft and draft.diff) or {}

        local remote = orig.remote or {}
        local orig_status = remote.status or orig.status or ""
        local orig_assignee = remote.assignee or orig.assignee or ""
        local orig_summary = remote.summary or orig.summary or ""
        local orig_labels = remote.labels or orig.labels or ""
        local eff_status = item.status ~= orig.status and item.status or orig_status
        local eff_assignee = item.assignee ~= orig.assignee and item.assignee or orig_assignee
        local eff_summary = item.summary ~= orig.summary and item.summary or orig_summary
        local eff_labels = item.labels ~= orig.labels and util.labels_to_string(item.labels) or orig_labels
        local eff_description = orig.description or ""
        local epic

        if draft_parsed then
          if draft_diff.status_changed then
            eff_status = draft_parsed.fields.status
          end
          if draft_diff.assignee_changed then
            eff_assignee = draft_parsed.fields.assignee
          end
          if draft_diff.summary_changed then
            eff_summary = draft_parsed.summary
          end
          if draft_diff.labels_changed then
            orig_labels = draft_diff.orig_labels
            eff_labels = draft_diff.new_labels
          end
          if draft_diff.description_changed then
            eff_description = draft_parsed.description or ""
          end
          if draft_diff.epic_changed then epic = draft_parsed.fields.epic end
        end

        local updates = {}
        if orig.section and item.section and orig.section ~= item.section then
          local dest = item.section == "backlog" and "BACKLOG" or "SPRINT"
          table.insert(mutations, { type = "MOVE", key = item.key, dest = dest })
        end

        if draft_diff.queued_for_removal then
          eff_status = config.options.defaults.close_status
          table.insert(updates, "Close issue " .. item.key .. ": " .. orig_status .. " -> " .. eff_status)
        elseif eff_status ~= orig_status then
          table.insert(updates, "status: " .. orig_status .. " -> " .. eff_status)
        end
        if eff_assignee ~= orig_assignee then table.insert(updates, "assignee: " .. orig_assignee .. " -> " .. eff_assignee) end
        if eff_summary ~= orig_summary then table.insert(updates, "summary: " .. orig_summary .. " -> " .. eff_summary) end
        local labels_changed = eff_labels ~= orig_labels
        if labels_changed then table.insert(updates, "labels: " .. orig_labels .. " -> " .. eff_labels) end
        if draft_diff.description_changed then table.insert(updates, "description: [changed]") end
        if epic ~= nil then
          local from = draft_diff.orig_epic_key ~= "" and draft_diff.orig_epic_key or "(none)"
          local to = draft_diff.new_epic_key ~= "" and draft_diff.new_epic_key or "(none)"
          table.insert(updates, "epic: " .. from .. " -> " .. to)
        end
        if draft_diff.components_changed then
          table.insert(updates, "components: " .. draft_diff.orig_components .. " -> " .. draft_diff.new_components)
        end
        local custom_updates = draft_diff.custom_field_updates or {}
        local custom_errors = draft_diff.custom_field_errors or {}
        if #custom_updates > 0 or #custom_errors > 0 then table.insert(updates, "custom fields: [changed]") end
        local edit_error = scratch.edit_error(item.key, draft_diff.type_changed or (item.type and item.type ~= orig.type),
          draft_diff.description_changed and eff_description or nil)
        if not edit_error and eff_summary == "" and eff_summary ~= orig_summary then
          edit_error = "Summary cannot be empty for " .. item.key .. "."
        end
        if #updates > 0 or edit_error then
          local effective_item = vim.deepcopy(item)
          effective_item.status = eff_status
          effective_item.assignee = eff_assignee
          effective_item.summary = eff_summary
          effective_item.labels = eff_labels
          effective_item.previous_labels = labels_changed and orig_labels or nil
          effective_item.description = eff_description
          effective_item.epic = epic
          effective_item.components = draft_diff.new_components
          effective_item.previous_components = draft_diff.components_changed and draft_diff.orig_components or nil
          effective_item.edit_error = edit_error
          effective_item.custom_field_updates = vim.deepcopy(custom_updates)
          effective_item.custom_field_errors = vim.deepcopy(custom_errors)
          local draft_fields = {}
          for _, field in ipairs({ "summary", "description", "assignee", "status", "epic", "labels", "components" }) do
            if draft_diff[field .. "_changed"] then draft_fields[field] = true end
          end
          table.insert(mutations, {
            type = "UPDATE", key = item.key, updates = updates, item = effective_item, row_fields = item,
            draft_fields = draft_fields, draft_buf = draft and draft.buf,
            close = draft_diff.queued_for_removal, draft_status = draft_diff.new_status,
          })
        end
      end
    end
  end

  -- A key that was present originally but no longer appears anywhere in the
  -- buffer was deleted as raw text (e.g. visual-mode delete). We deliberately
  -- do NOT infer a section MOVE from this: doing so silently ran `sprint add`
  -- on deleted backlog lines (adding them to the active sprint) and a no-op
  -- "unsupported" warning on deleted sprint lines. Section moves must be
  -- explicit -- relocate the line between Sprint/Backlog in the `all` view
  -- (handled by the section diff above) or use the explicit close queue (gX).
  local removed_keys = {}
  for _, item in ipairs(original) do
    if not current_by_key[item.key] then
      table.insert(removed_keys, item.key)
    end
  end
  if #removed_keys > 0 then
    vim.notify(
      "Ignored "
        .. #removed_keys
        .. " deleted line(s): "
        .. table.concat(removed_keys, ", ")
        .. ". Use >> / << in the jira-oil://all view to move between Sprint and Backlog, "
        .. "or 'gX' to queue an issue close.",
      vim.log.levels.WARN
    )
  end

  return mutations, removed_keys
end

local function validate_mutations(mutations)
  for _, mutation in ipairs(mutations) do
    if mutation.item and mutation.item.edit_error then
      vim.notify(mutation.item.edit_error, vim.log.levels.ERROR)
      return false
    end
    local errors = mutation.item and mutation.item.custom_field_errors or {}
    if #errors > 0 then
      vim.notify(table.concat(errors, "\n"), vim.log.levels.ERROR)
      return false
    end
  end
  return true
end

---Save view and execute mutations
---@param buf number
function M.save(buf)
  if save_in_progress(buf) then return end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local mutations, removed_keys = M.compute_diff(buf)
  if not validate_mutations(mutations) then return end
  if #mutations == 0 then
    -- Deleted lines produce no mutation (they're intentionally ignored). When a
    -- deletion is the only edit, restore the buffer from cache so the removed
    -- line(s) reappear instead of leaving the view out of sync with Jira. When
    -- there are real mutations, the post-execute refresh already restores them.
    if removed_keys and #removed_keys > 0 then
      require("jira-oil.view").reset(buf, { after_save = true })
    end
    vim.notify("No changes to apply.", vim.log.levels.INFO)
    vim.bo[buf].modified = false
    return
  end

  local lines = { "Pending Mutations:" }
  for _, m in ipairs(mutations) do
    if m.type == "CREATE" then
      table.insert(lines, "[CREATE] New Task: " .. (m.item.summary or ""))
    elseif m.type == "UPDATE" then
      if m.updates[1] and m.updates[1]:match("^Close issue ") then
        table.insert(lines, table.concat(m.updates, ", "))
      else
        table.insert(lines, "[UPDATE] " .. m.key .. ": " .. table.concat(m.updates, ", "))
      end
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
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      vim.notify("The Jira list changed. Save again to review the current edits.", vim.log.levels.WARN)
      return
    end
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
  if not vim.api.nvim_buf_is_valid(buf) or save_in_progress(buf) or not validate_mutations(mutations) then return end
  local view = require("jira-oil.view")
  local scratch = require("jira-oil.scratch")
  local keys = {}
  for _, mutation in ipairs(mutations) do
    if mutation.key then table.insert(keys, mutation.key) end
  end
  local release = scratch.reserve_updates(keys)
  if not release then return end
  saving[buf] = true
  local saved_tick = vim.api.nvim_buf_get_changedtick(buf)
  local data = view.cache[buf]
  local original_by_key = {}
  for _, item in ipairs((data and data.original) or {}) do
    if item and item.key then
      original_by_key[item.key] = item
    end
  end
  local total = #mutations
  local has_create = false

  for _, m in ipairs(mutations) do
    if m.type == "CREATE" then
      has_create = true
      local row = m.item.row
      if row ~= nil then
        m.create_anchor = vim.api.nvim_buf_set_extmark(buf, create_anchors, row, 0, {
          end_row = row + 1, end_col = 0, end_right_gravity = false, invalidate = true,
        })
      end
    end
  end

  -- Mutations run one at a time and stop at the first failure. Each success
  -- is folded into the cached baseline so that, while the buffer keeps the
  -- unapplied edits, a re-save only retries what is left (and never repeats
  -- a CREATE that already went through).
  local function fold_into_baseline(m)
    if not data then
      return
    end
    if m.type == "CREATE" then
      local item = vim.deepcopy(m.item)
      item.key = m.created_key
      item.is_new, item.row, item.source_key = nil, nil, nil
      if m.status_failed then
        item.status = config.options.defaults.status
      end
      table.insert(data.original, item)
      original_by_key[item.key] = item
    elseif m.type == "MOVE" and m.dest == "SPRINT" then
      local orig = original_by_key[m.key]
      if orig then
        orig.section = "sprint"
      end
    end
  end

  local function finish_all(applied, failed_at)
    saving[buf] = nil
    release()
    cli.clear_cache("all")
    local valid = vim.api.nvim_buf_is_valid(buf)
    if valid then vim.api.nvim_buf_clear_namespace(buf, create_anchors, 0, -1) end
    if not failed_at then
      vim.notify("All changes applied successfully!", vim.log.levels.INFO)
      if not valid or view.cache[buf] ~= data or vim.api.nvim_buf_get_changedtick(buf) ~= saved_tick then
        return
      end
      vim.bo[buf].modified = false
      view.refresh(buf, { after_save = true })
      if has_create then
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(buf) and not saving[buf] then
            view.refresh(buf, { after_save = true })
          end
        end, 1200)
      end
      return
    end
    local skipped = total - failed_at
    vim.notify(
      string.format(
        "Stopped at the first failure: %d of %d changes applied, %d not attempted. "
          .. "Your edits are kept; fix the failing one and :w to retry the rest.",
        applied,
        total,
        skipped
      ),
      vim.log.levels.WARN
    )
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

      local epic_key = util.extract_epic_key(util.resolve_epic_from_fields(fields))
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

      local updates, errors = custom.for_create(config.options.custom_fields, fields)
      if #errors > 0 then return nil, table.concat(errors, "\n") .. "\nOpen the issue editor to fill the required custom fields." end
      custom.append_args(args, updates, true)
      return args
    end

    local function after_create_success(m, stdout, stderr, finish)
      local item = m.item
      local key = util.extract_issue_key((stdout or "") .. "\n" .. (stderr or ""))
      if not key then
        -- The issue exists but the row can't be tied to it; re-saving would
        -- create it a second time.
        vim.notify(
          "Issue \"" .. (item.summary or "") .. "\" was created but its key could not be read. "
            .. "Refresh (or delete that row) before saving again.",
          vim.log.levels.ERROR
        )
        finish(false)
        return
      end
      m.created_key = key
      if m.create_anchor and vim.api.nvim_buf_is_valid(buf) then
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, create_anchors, m.create_anchor, { details = true })
        if #pos > 0 and not pos[3].invalid then
          view.set_line_key(buf, pos[1], key)
          view.clear_copy_source_at_line(buf, pos[1])
        end
      end

      local status = item.status or ""
      if status ~= "" and status ~= config.options.defaults.status then
        cli.exec({ "issue", "move", key, status }, function(_, stderr, code)
          if code ~= 0 then
            vim.notify("Failed to set status for " .. key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
            -- The issue itself exists: keep it in the baseline at its
            -- initial status so a re-save retries only the move.
            m.status_failed = true
            fold_into_baseline(m)
            finish(false)
            return
          end
          finish(true)
        end)
      else
        finish(true)
      end
    end

    local function run_one(m, finish)
      if m.type == "CREATE" then
        local function create_with_source(source_issue)
          local args, err = build_create_args(m.item, source_issue)
          if not args then
            vim.notify(err, vim.log.levels.ERROR)
            finish(false)
            return
          end
          cli.exec(args, function(stdout, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to create issue: " .. (stderr or ""), vim.log.levels.ERROR)
              finish(false)
              return
            end
            after_create_success(m, stdout, stderr, finish)
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
        local description_changed = false
        local assignee_changed = false
        local status_changed = false
        local custom_updates = m.item.custom_field_updates or {}
        for _, update in ipairs(m.updates) do
          if update:match("^summary:") then summary_changed = true end
          if update:match("^description:") then description_changed = true end
          if update:match("^assignee:") then assignee_changed = true end
          if update:match("^status:") or update:match("^Close issue ") then status_changed = true end
        end

        local function record(saved, closed)
          local orig = original_by_key[m.key]
          if orig then
            orig.remote = orig.remote or {}
            for field, value in pairs(saved) do
              orig.remote[field] = value
              if m.row_fields and m.row_fields[field] ~= nil then
                -- Keep the baseline for the text that is still displayed. An
                -- issue-editor change need not be present on that list row.
                orig[field] = m.row_fields[field]
              end
            end
          end
          scratch.commit_fields(m.key, saved, {
            from_list = true, draft_fields = m.draft_fields or {}, draft_buf = m.draft_buf,
            close = closed, draft_status = m.draft_status,
          })
        end

        local function do_status(skip_on_error)
          if skip_on_error or not status_changed then
            finish(not skip_on_error)
            return
          end
          cli.exec({ "issue", "move", m.key, m.item.status }, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update status " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
            else
              record({ status = m.item.status }, m.close)
            end
            finish(code == 0)
          end)
        end

        local function do_metadata(skip_on_error)
          if skip_on_error or (m.item.previous_labels == nil and m.item.previous_components == nil) then
            do_status(skip_on_error)
            return
          end

          local args = { "issue", "edit", m.key, "--no-input" }
          local saved = {}
          if m.item.previous_labels ~= nil then
            cli.append_list_delta(args, "--label", m.item.previous_labels, m.item.labels)
            saved.labels = m.item.labels
          end
          if m.item.previous_components ~= nil then
            cli.append_list_delta(args, "--component", m.item.previous_components, m.item.components)
            saved.components = m.item.components
          end

          if #args == 4 then
            record(saved)
            do_status(false)
            return
          end

          cli.exec(args, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update labels or components for " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
            else
              record(saved)
            end
            do_status(code ~= 0)
          end)
        end

        local function do_epic(skip_on_error)
          if skip_on_error or m.item.epic == nil then
            do_metadata(skip_on_error)
            return
          end
          cli.set_issue_epic(m.key, util.extract_epic_key(m.item.epic), function(ok)
            if ok then record({ epic = m.item.epic }) end
            do_metadata(not ok)
          end)
        end

        local function do_assign(skip_on_error)
          if skip_on_error or not assignee_changed then
            do_epic(skip_on_error)
            return
          end

          local function assign_with_value(assignee)
            local project = util.issue_project_from_key(m.key) or ""
            local cmd = { "issue", "assign", m.key, assignee }
            if project ~= "" then
              table.insert(cmd, "--project")
              table.insert(cmd, project)
            end
            cli.exec(cmd, function(_, stderr, code)
              if code ~= 0 then
                vim.notify("Failed to update assignee " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
                do_epic(true)
              else
                record({ assignee = m.item.assignee })
                do_epic(false)
              end
            end)
          end

          local assignee_input = m.item.assignee
          if assignee_input == "Unassigned" then
            assign_with_value("x")
            return
          end

          -- Fast path: already a CLI-friendly token (login/account key), or
          -- explicit mapping notation "Name -> login".
          local resolved = util.resolve_assignee_for_cli(assignee_input, nil)
          if resolved and resolved ~= "" then
            assign_with_value(resolved)
            return
          end

          -- Fallback path: try to resolve from the current assignee object.
          cli.get_issue(m.key, function(issue)
            local source_assignee = issue and issue.fields and issue.fields.assignee or nil
            local resolved_from_source = util.resolve_assignee_for_cli(assignee_input, source_assignee)
            assign_with_value((resolved_from_source and resolved_from_source ~= "") and resolved_from_source or assignee_input)
          end)
        end

        if summary_changed or description_changed or #custom_updates > 0 then
          local args = { "issue", "edit", m.key, "--no-input" }
          local saved = {}
          if summary_changed then
            vim.list_extend(args, { "-s", m.item.summary })
            saved.summary = m.item.summary
          end
          if description_changed then
            vim.list_extend(args, { "--body", m.item.description })
            saved.description = m.item.description
          end
          custom.append_args(args, custom_updates, false)
          cli.exec(args, function(_, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update issue " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              do_assign(true)
            else
              if next(saved) then record(saved) end
              if #custom_updates > 0 then scratch.commit_custom_fields(m.key, custom_updates) end
              do_assign(false)
            end
          end)
        else
          do_assign(false)
        end
      elseif m.type == "MOVE" then
        if m.dest == "SPRINT" then
          if sprint_id then
            cli.exec({ "sprint", "add", tostring(sprint_id), m.key }, function(stdout, stderr, code)
              if code ~= 0 then
                vim.notify("Failed to move to sprint " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              end
              finish(code == 0)
            end)
          else
            vim.notify("Active sprint not found. Cannot move " .. m.key .. " to sprint.", vim.log.levels.WARN)
            finish(false)
          end
        elseif m.dest == "BACKLOG" then
          vim.notify("Moving to backlog is not supported by jira-cli. The move was not applied.", vim.log.levels.WARN)
          finish(false)
        end
      end
    end

    local applied = 0
    local function step(i)
      local m = mutations[i]
      if not m then
        finish_all(applied, nil)
        return
      end
      run_one(m, function(ok)
        if not ok then
          finish_all(applied, i)
          return
        end
        applied = applied + 1
        fold_into_baseline(m)
        step(i + 1)
      end)
    end
    step(1)
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
