local config = require("jira-oil.config")

local M = {}

function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    
    local start_col = col
    while start_col > 0 and line:sub(start_col, start_col):match("[^│]") do
      start_col = start_col - 1
    end
    
    -- Keep the space after the pipe character if it exists
    if start_col > 0 and line:sub(start_col + 1, start_col + 1) == " " then
      start_col = start_col + 1
    end

    return start_col
  else
    local completions = {}
    local buf = vim.api.nvim_get_current_buf()
    local kind = vim.b[buf].jira_oil_kind
    
    -- Right now we only provide omnifunc for the list view to complete status
    if kind == "list" then
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local parts = vim.split(line, "│", { plain = true })
      
      -- Find which column we are in based on cursor position
      local current_col_idx = 1
      local byte_count = 0
      for i, part in ipairs(parts) do
        byte_count = byte_count + #part + 3 -- 3 bytes for '│'
        if col < byte_count then
          current_col_idx = i
          break
        end
      end
      
      -- Assuming standard setup, column 1 is status
      local cols = config.options.view.columns
      local col_name = cols[current_col_idx] and cols[current_col_idx].name
      
      if col_name == "status" then
        local statuses = { "Open", "To Do", "In Progress", "In Review", "Done", "Closed", "Blocked" }
        for _, s in ipairs(statuses) do
          if s:lower():match("^" .. vim.trim(base):lower()) then
            table.insert(completions, {
              word = s,
              menu = "[Status]",
            })
          end
        end
      elseif col_name == "type" then
        local types = { "Task", "Story", "Epic", "Sub-task", "Bug", "Improvement", "Feature" }
        for _, t in ipairs(types) do
          if t:lower():match("^" .. vim.trim(base):lower()) then
            table.insert(completions, {
              word = t,
              menu = "[Type]",
            })
          end
        end
      end
    end
    
    return completions
  end
end

return M
