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

---Look up an icon from a configurable map with a "default" fallback
---@param icon_map table<string, string>
---@param name string
---@return string
function M.get_icon(icon_map, name)
  if not icon_map then return "" end
  return icon_map[name] or icon_map["default"] or ""
end

---Strip a leading icon prefix (non-ASCII char + space) from a value.
---Tolerant: returns the original string if no icon is present.
---@param text string
---@return string
function M.strip_icon(text)
  -- Icons are a single multi-byte character followed by a space.
  -- Match any character outside printable ASCII (0x20-0x7E) at the start.
  local stripped = text:gsub("^[^\032-\126]+ ", "")
  return stripped
end

---@param key string|nil
---@return boolean
function M.is_newtask_key(key)
  return type(key) == "string" and key:match("%-NEWTASK$") ~= nil
end

---@param key string|nil
---@return string|nil
function M.issue_project_from_key(key)
  if type(key) ~= "string" then
    return nil
  end
  return key:match("^([A-Z0-9]+)%-%d+$")
end

---@param text string|nil
---@return string|nil
function M.extract_issue_key(text)
  if type(text) ~= "string" then
    return nil
  end
  return text:match("([A-Z][A-Z0-9]+%-%d+)")
end

---@param input string|nil
---@param source_assignee table|nil
---@return string|nil
function M.resolve_assignee_for_cli(input, source_assignee)
  local function is_cli_token(s)
    return s:match("^[%w%._%-@]+$") ~= nil
  end

  local value = M.trim(input or "")
  -- Allow explicit mapping notation, e.g. "Full Name -> login"
  -- or "Full Name → login"; RHS wins when present.
  do
    local mapped = value:match("%-%>%s*(.+)$") or value:match("→%s*(.+)$")
    if mapped then
      mapped = M.trim(mapped)
      if mapped ~= "" then
        value = mapped
      end
    end
  end

  if value == "" then
    return nil
  end
  if value == "Unassigned" then
    return nil
  end

  local src_login = ""
  local src_display = ""
  if source_assignee then
    src_login = source_assignee.name or source_assignee.key or source_assignee.accountId or source_assignee.emailAddress or ""
    src_display = source_assignee.displayName or src_login
  end

  if src_login ~= "" then
    if value == src_login then
      return src_login
    end
    if value == src_display then
      return src_login
    end
    if value:find("…", 1, true) or value:find("...", 1, true) then
      local prefix = value:gsub("…", ""):gsub("%.%.%.", "")
      if prefix ~= "" and src_display:sub(1, #prefix) == prefix then
        return src_login
      end
    end
  end

  if is_cli_token(value) then
    return value
  end

  return nil
end

---@param s string|nil
---@return string
function M.uri_encode(s)
  s = tostring(s or "")
  return (s:gsub("([^%w%-%._~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

---@param s string|nil
---@return string
function M.uri_decode(s)
  s = tostring(s or "")
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

---@param value string|string[]|nil
---@return string[]
function M.labels_to_list(value)
  local out = {}

  if type(value) == "table" then
    for _, label in ipairs(value) do
      label = vim.trim(tostring(label or ""))
      if label ~= "" then
        table.insert(out, label)
      end
    end
    table.sort(out)
    return out
  end

  if type(value) ~= "string" or value == "" then
    return out
  end

  for label in string.gmatch(value, "[^,]+") do
    label = vim.trim(label)
    if label ~= "" then
      table.insert(out, label)
    end
  end

  table.sort(out)
  return out
end

---@param value string|string[]|nil
---@return string
function M.labels_to_string(value)
  return table.concat(M.labels_to_list(value), ", ")
end

---@param value string|string[]|nil
---@return table<string, boolean>
function M.labels_to_set(value)
  local set = {}
  for _, label in ipairs(M.labels_to_list(value)) do
    set[label] = true
  end
  return set
end

return M
