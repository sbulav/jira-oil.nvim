-- Headless test entrypoint.
--
--   nvim --clean -l tests/run.lua
--   make test
--
-- Resolves the repo root from this script's own path so it works regardless of
-- the current working directory, wires up package.path for both the plugin
-- (lua/) and the test helpers (tests/), then loads and runs every *_spec.lua.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h")

package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local t = require("minitest")

local specs = vim.fn.glob(root .. "/tests/*_spec.lua", true, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  local name = vim.fn.fnamemodify(spec, ":t:r")
  require(name)
end

t.run()
