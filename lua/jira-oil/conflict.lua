local M = {}

local function trim(s)
  return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function normalize_components(list)
  local out = {}
  if type(list) == "string" then
    for comp in list:gmatch("[^,]+") do
      comp = trim(comp)
      if comp ~= "" then
        table.insert(out, comp)
      end
    end
  elseif type(list) == "table" then
    for _, comp in ipairs(list) do
      if type(comp) == "string" then
        comp = trim(comp)
        if comp ~= "" then
          table.insert(out, comp)
        end
      elseif type(comp) == "table" and comp.name and comp.name ~= "" then
        table.insert(out, trim(comp.name))
      end
    end
  end
  table.sort(out)
  return out
end

local function first_non_empty(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" and trim(v) ~= "" then
      return trim(v)
    end
  end
  return ""
end

---@param issue table|nil
---@param epic_field string|nil
---@return table
function M.snapshot_issue(issue, epic_field)
  issue = issue or {}
  local fields = issue.fields or {}

  local assignee = "Unassigned"
  if fields.assignee then
    assignee = first_non_empty(fields.assignee.displayName, fields.assignee.name, fields.assignee.accountId)
    if assignee == "" then
      assignee = "Unassigned"
    end
  end

  local status = first_non_empty(fields.status and fields.status.name, fields.status)
  local summary = first_non_empty(fields.summary)
  local description = first_non_empty(fields.description)

  local issue_type = ""
  do
    local itype = fields.issuetype or fields.issueType
    if type(itype) == "table" then
      issue_type = first_non_empty(itype.name)
    elseif type(itype) == "string" then
      issue_type = first_non_empty(itype)
    end
  end

  local epic_key = ""
  if fields.parent and fields.parent.key then
    epic_key = first_non_empty(fields.parent.key)
  elseif epic_field and epic_field ~= "" and type(fields[epic_field]) == "string" then
    epic_key = first_non_empty(fields[epic_field]:match("([A-Z0-9]+%-%d+)"))
  end

  return {
    key = first_non_empty(issue.key),
    summary = summary,
    description = description,
    assignee = assignee,
    status = status,
    issue_type = issue_type,
    epic_key = epic_key,
    components = normalize_components(fields.components or {}),
  }
end

---@param item table|nil
---@return table
function M.snapshot_structured(item)
  item = item or {}
  return {
    key = first_non_empty(item.key),
    summary = first_non_empty(item.summary),
    description = first_non_empty(item.description),
    assignee = first_non_empty(item.assignee),
    status = first_non_empty(item.status),
    issue_type = first_non_empty(item.type),
    section = first_non_empty(item.section),
    components = normalize_components(item.components or {}),
    epic_key = first_non_empty(item.epic_key),
  }
end

local function component_signature(components)
  return table.concat(components or {}, ",")
end

---@param base table
---@param latest table
---@param fields string[]
---@return boolean
---@return string[]
function M.detect_conflicts(base, latest, fields)
  local conflicts = {}
  local wanted = {}
  for _, field in ipairs(fields or {}) do
    wanted[field] = true
  end

  local function check(field, a, b)
    if wanted[field] and (a or "") ~= (b or "") then
      table.insert(conflicts, field)
    end
  end

  check("summary", base.summary, latest.summary)
  check("description", base.description, latest.description)
  check("assignee", base.assignee, latest.assignee)
  check("status", base.status, latest.status)
  check("issue_type", base.issue_type, latest.issue_type)
  check("epic_key", base.epic_key, latest.epic_key)
  if wanted.components then
    check("components", component_signature(base.components), component_signature(latest.components))
  end
  if wanted.section then
    check("section", base.section, latest.section)
  end

  return #conflicts > 0, conflicts
end

return M
