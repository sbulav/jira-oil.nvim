local parser = require("jira-oil.parser")
local cli = require("jira-oil.cli")
local config = require("jira-oil.config")

local M = {}

---Diff buffer lines with original to compute mutations
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

  for _, line in ipairs(lines) do
    if line:match("%S") then
      local parsed = parser.parse_line(line)
      if parsed then
        table.insert(current, parsed)
      end
    end
  end

  local function find_original(key)
    for _, item in ipairs(original) do
      if item.key == key then return item end
    end
    return nil
  end

  for _, item in ipairs(current) do
    if item.is_new then
      table.insert(mutations, { type = "CREATE", item = item })
    else
      local orig = find_original(item.key)
      if orig then
        local updates = {}
        if item.status ~= orig.status then table.insert(updates, "status: " .. orig.status .. " -> " .. item.status) end
        if item.assignee ~= orig.assignee then table.insert(updates, "assignee: " .. orig.assignee .. " -> " .. item.assignee) end
        if item.summary ~= orig.summary then table.insert(updates, "summary: " .. orig.summary .. " -> " .. item.summary) end
        if #updates > 0 then
          table.insert(mutations, { type = "UPDATE", key = item.key, updates = updates, item = item })
        end
      end
    end
  end

  local function find_current(key)
    for _, item in ipairs(current) do
      if item.key == key then return item end
    end
    return nil
  end

  for _, item in ipairs(original) do
    if not find_current(item.key) then
      local dest = data.target == "sprint" and "BACKLOG" or "SPRINT"
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

  local function check_done()
    done = done + 1
    if done >= total then
      if not has_errors then
        vim.notify("All changes applied successfully!", vim.log.levels.INFO)
      end
      view.refresh(buf)
    end
  end

  local function apply_mutations(sprint_id)
    for _, m in ipairs(mutations) do
      if m.type == "CREATE" then
        local args = { "issue", "create", "-t", m.item.type, "-s", m.item.summary, "--no-input" }
        local proj = config.options.defaults.project
        if proj ~= "" then table.insert(args, "-p"); table.insert(args, proj) end
        if m.item.assignee ~= "Unassigned" then table.insert(args, "-a"); table.insert(args, m.item.assignee) end

        cli.exec(args, function(stdout, stderr, code)
          if code ~= 0 then
            vim.notify("Failed to create issue: " .. (stderr or ""), vim.log.levels.ERROR)
            has_errors = true
          else
            -- If we created a task in the SPRINT view, we might need to add it to sprint?
            -- Since the requirement says "creating tasks should be put in the backlog", we do nothing.
          end
          check_done()
        end)
      elseif m.type == "UPDATE" then
        local summary_changed = false
        local args = { "issue", "edit", m.key, "--no-input" }
        for _, update in ipairs(m.updates) do
          if update:match("^summary:") then
            table.insert(args, "-s")
            table.insert(args, m.item.summary)
            summary_changed = true
          end
        end

        local function do_assign_and_status()
          local assignee_changed = false
          for _, update in ipairs(m.updates) do
            if update:match("^assignee:") then assignee_changed = true end
          end
          
          local function do_status()
            local status_changed = false
            for _, update in ipairs(m.updates) do
              if update:match("^status:") then status_changed = true end
            end
            if status_changed then
              cli.exec({ "issue", "move", m.key, m.item.status, "--no-input" }, function(s3, e3, c3)
                if c3 ~= 0 then
                  vim.notify("Failed to update status " .. m.key .. ": " .. (e3 or ""), vim.log.levels.ERROR)
                  has_errors = true
                end
                check_done()
              end)
            else
              check_done()
            end
          end

          if assignee_changed then
            local assignee = m.item.assignee
            if assignee == "Unassigned" then assignee = "x" end
            cli.exec({ "issue", "assign", m.key, assignee, "--no-input" }, function(s2, e2, c2)
              if c2 ~= 0 then
                vim.notify("Failed to update assignee " .. m.key .. ": " .. (e2 or ""), vim.log.levels.ERROR)
                has_errors = true
              end
              do_status()
            end)
          else
            do_status()
          end
        end

        if summary_changed then
          cli.exec(args, function(stdout, stderr, code)
            if code ~= 0 then
              vim.notify("Failed to update summary " .. m.key .. ": " .. (stderr or ""), vim.log.levels.ERROR)
              has_errors = true
            end
            do_assign_and_status()
          end)
        else
          do_assign_and_status()
        end
      elseif m.type == "MOVE" then
        if m.dest == "SPRINT" then
          if sprint_id then
            cli.exec({ "sprint", "add", sprint_id, m.key, "--no-input" }, function(stdout, stderr, code)
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
          -- We cannot directly remove from sprint. We could use `jira issue move` or ignore it.
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
