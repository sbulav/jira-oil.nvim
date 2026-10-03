-- Explicitly selected fields, rendered independently of Jira's native shapes.
local M = {}
local types = { text = true, number = true, date = true, single_select = true, multi_select = true }

function M.validate_definitions(definitions)
  assert(type(definitions) == "table" and (vim.islist or vim.tbl_islist)(definitions), "custom_fields must be a list")
  local ids, names = {}, {}
  for _, field in ipairs(definitions) do
    assert(type(field) == "table", "custom_fields entries must be tables")
    assert(type(field.id) == "string" and field.id:match("^customfield_%d+$"), "custom_fields.id must be customfield_<number>")
    assert(type(field.cli_name) == "string" and field.cli_name ~= "" and not field.cli_name:find('[%s,="]'),
      "custom_fields.cli_name must be a jira-cli alias without whitespace, commas, quotes, or equals")
    assert(types[field.type], "unsupported custom_fields.type")
    assert(not ids[field.id] and not names[field.cli_name:lower()], "custom_fields IDs and CLI aliases must be unique")
    assert(field.label == nil or (type(field.label) == "string" and not field.label:find("[\r\n]")), "custom_fields.label must be one line")
    assert(field.required == nil or type(field.required) == "boolean", "custom_fields.required must be boolean")
    if field.options then
      assert((field.type == "single_select" or field.type == "multi_select") and type(field.options) == "table"
        and (vim.islist or vim.tbl_islist)(field.options), "custom_fields.options must be a selection's list of strings")
      for _, option in ipairs(field.options) do
        assert(type(option) == "string" and option ~= "" and not option:find("[\r\n]"), "custom_fields.options must contain nonempty single-line strings")
        assert(field.type ~= "multi_select" or (not option:find(",", 1, true) and option:sub(1, 1) ~= "-"),
          "multi_select options cannot contain commas or start with '-' (jira-cli limitation)")
      end
    end
    ids[field.id], names[field.cli_name:lower()] = true, true
  end
end

function M.label(field)
  return field.label or field.cli_name
end

local function fail(field, message)
  return nil, M.label(field) .. ": " .. message
end

local function allowed(field, value)
  return not field.options or vim.tbl_contains(field.options, value)
end

function M.normalize(field, text)
  if type(text) ~= "string" then return fail(field, "value must be text") end
  if field.type == "text" then return text end
  text = vim.trim(text)
  if text == "" then return "" end
  if text:find("[\r\n]") then return fail(field, "value must occupy one line") end
  if field.type == "number" then
    local number = tonumber(text)
    if text:find("[^%d%.%+%-eE]") or not number or number ~= number or math.abs(number) == math.huge then
      return fail(field, "enter a finite decimal number")
    end
    return tostring(number)
  elseif field.type == "date" then
    local year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    local leap = year and (year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0))
    local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if not year or year < 1 or not days[month] or day < 1 or day > days[month] then
      return fail(field, "enter a valid date as YYYY-MM-DD")
    end
    return text
  elseif field.type == "single_select" then
    if not allowed(field, text) then return fail(field, "value is not in configured options") end
    return text
  elseif field.type == "multi_select" then
    local values, seen = {}, {}
    for _, part in ipairs(vim.split(text, ",", { plain = true })) do
      local value = vim.trim(part)
      if value == "" or value:sub(1, 1) == "-" or not allowed(field, value) then
        return fail(field, "enter comma-separated options (no empty values or leading '-')")
      end
      if not seen[value] then table.insert(values, value); seen[value] = true end
    end
    table.sort(values)
    return table.concat(values, ",")
  end
  return fail(field, "unsupported field type")
end

-- Unknown API shapes remain visible but cannot be rewritten accidentally.
function M.display(field, value)
  if value == nil or value == vim.NIL then return "" end
  if field.type == "single_select" and type(value) == "table" then value = value.value end
  if field.type == "multi_select" and type(value) == "table" and (vim.islist or vim.tbl_islist)(value) then
    local values = {}
    for _, option in ipairs(value) do
      local name = type(option) == "table" and option.value or option
      if type(name) ~= "string" or name:find(",", 1, true) or name:sub(1, 1) == "-" then
        return "[Unsupported Jira value]", M.label(field) .. ": Jira value cannot be represented by jira-cli"
      end
      table.insert(values, name)
    end
    value = table.concat(values, ",")
  elseif field.type == "number" and type(value) == "number" then
    value = tostring(value)
  end
  if type(value) ~= "string" then
    return "[Unsupported Jira value]", M.label(field) .. ": unexpected Jira value shape; field is read-only"
  end
  -- Preserve fetched values even if an optional local options list excludes them.
  return value
end

-- Keep raw buffer values in drafts; transport updates carry validated values.
function M.diff(definitions, current, original, read_errors, creating)
  local updates, errors = {}, {}
  for _, field in ipairs(definitions or {}) do
    local text, before = (current or {})[field.id], (original or {})[field.id] or ""
    if text ~= nil then
      local changed = text ~= before
      if read_errors and read_errors[field.id] then
        if changed or creating then table.insert(errors, read_errors[field.id]) end
      elseif changed or creating or (field.required and vim.trim(text) == "") then
        local value, err = M.normalize(field, text)
        if not err and field.required and vim.trim(value) == "" then err = M.label(field) .. ": value is required" end
        local baseline = M.normalize(field, before) or before
        if not err and not creating and value == "" and baseline ~= ""
          and field.type ~= "text" and field.type ~= "multi_select" then
          err = M.label(field) .. ": jira-cli cannot clear this type to null; restore its value"
        end
        if err then
          table.insert(errors, err)
        elseif (creating and value ~= "") or (not creating and value ~= baseline) then
          table.insert(updates, { field = vim.deepcopy(field), value = value, previous = baseline })
        end
      end
    else
      table.insert(errors, M.label(field) .. ": field row is missing; reset the issue editor")
    end
  end
  return updates, errors
end

function M.apply(fields, updates)
  for _, update in ipairs(updates or {}) do
    local field, value = update.field, update.value
    if field.type == "number" then
      fields[field.id] = tonumber(value)
    elseif field.type == "single_select" then
      fields[field.id] = { value = value }
    elseif field.type == "multi_select" then
      fields[field.id] = {}
      if value ~= "" then
        for _, option in ipairs(vim.split(value, ",", { plain = true })) do
          table.insert(fields[field.id], { value = option })
        end
      end
    else
      fields[field.id] = value
    end
  end
end

local function selection_set(text)
  local set = {}
  if text and text ~= "" then
    for _, value in ipairs(vim.split(text, ",", { plain = true })) do set[value] = true end
  end
  return set
end

function M.append_args(args, updates, creating)
  local entries = {}
  for _, update in ipairs(updates or {}) do
    local field, value = update.field, update.value
    if field.type == "multi_select" and not creating then
      local before, after = selection_set(update.previous), selection_set(value)
      local delta = {}
      for option in pairs(before) do if not after[option] then table.insert(delta, "-" .. option) end end
      for option in pairs(after) do if not before[option] then table.insert(delta, option) end end
      table.sort(delta)
      value = table.concat(delta, ",")
    end
    table.insert(entries, field.cli_name .. "=" .. value)
  end
  if #entries == 0 then return end
  -- pflag.StringToString special-cases a single '=' and strips literal quotes.
  -- Duplicate a lone pair to force its CSV decoder; the resulting map is identical.
  if #entries == 1 then table.insert(entries, entries[1]) end
  for i, pair in ipairs(entries) do entries[i] = '"' .. pair:gsub('"', '""') .. '"' end
  vim.list_extend(args, { "--custom", table.concat(entries, ",") })
end

function M.for_create(definitions, fields)
  local current, errors = {}, {}
  for _, field in ipairs(definitions or {}) do
    local text, err = M.display(field, (fields or {})[field.id])
    current[field.id], errors[field.id] = text, err
  end
  local updates, problems = M.diff(definitions, current, {}, nil, true)
  for _, err in pairs(errors) do table.insert(problems, err) end
  return updates, problems
end

return M
