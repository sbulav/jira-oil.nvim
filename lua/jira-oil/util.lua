local M = {}

---Format a string to a fixed width
---@param str string
---@param width number
---@return string
function M.pad_right(str, width)
  local len = vim.fn.strchars(str)
  if len > width then
    return vim.fn.strcharpart(str, 0, width - 1) .. "…"
  end
  return str .. string.rep(" ", width - len)
end

---Trim string
---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

return M
