-- Backwards-compatible alias for the real test runner.
-- Prefer `make test` or `nvim --clean -l tests/run.lua`.
dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/run.lua")
