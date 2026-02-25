local M = {}

---Format a string to a fixed display width
---@param str string
---@param width number
---@return string
function M.pad_right(str, width)
  local display_width = vim.api.nvim_strwidth(str)
  if display_width > width then
    -- Truncate by characters until display width fits, then add ellipsis
    local chars = vim.fn.strchars(str)
    for i = chars - 1, 0, -1 do
      local truncated = vim.fn.strcharpart(str, 0, i)
      if vim.api.nvim_strwidth(truncated) <= width - 1 then
        return truncated .. "…"
      end
    end
    return "…"
  end
  return str .. string.rep(" ", width - display_width)
end

---Trim string
---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

return M
