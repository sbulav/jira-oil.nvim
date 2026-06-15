-- Tiny zero-dependency test framework for headless Neovim.
--
-- Specs call `require("minitest").test(name, fn)` to register a case and use
-- `eq` / `ok` for assertions. `tests/run.lua` requires the specs and then
-- calls `run()`, which prints a summary and exits non-zero on any failure.

local M = { tests = {} }

---@param name string
---@param fn fun()
function M.test(name, fn)
  table.insert(M.tests, { name = name, fn = fn })
end

local function deep_eq(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function fmt(v)
  if type(v) == "table" then
    return vim.inspect(v)
  end
  return tostring(v)
end

---Assert deep equality.
function M.eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    error(
      (msg or "values differ")
        .. "\n  expected: "
        .. fmt(expected)
        .. "\n  actual:   "
        .. fmt(actual),
      2
    )
  end
end

---Assert a truthy value.
function M.ok(cond, msg)
  if not cond then
    error(msg or "expected a truthy value", 2)
  end
end

---Assert that the value is nil.
function M.is_nil(value, msg)
  if value ~= nil then
    error((msg or "expected nil, got ") .. fmt(value), 2)
  end
end

---Run all registered tests and exit the process with an appropriate code.
function M.run()
  local passed, failed = 0, 0
  local failures = {}

  for _, tc in ipairs(M.tests) do
    local ok, err = pcall(tc.fn)
    if ok then
      passed = passed + 1
      print("  ok   " .. tc.name)
    else
      failed = failed + 1
      table.insert(failures, { name = tc.name, err = err })
      print("  FAIL " .. tc.name)
    end
  end

  if #failures > 0 then
    print("")
    for _, f in ipairs(failures) do
      print("FAIL: " .. f.name)
      print("  " .. tostring(f.err))
    end
  end

  print(string.format("\n%d passed, %d failed, %d total", passed, failed, passed + failed))
  io.flush()
  os.exit(failed == 0 and 0 or 1)
end

return M
