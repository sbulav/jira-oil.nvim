.PHONY: test

# Run the headless test suite. Requires `nvim` on PATH.
test:
	nvim --clean -l tests/run.lua
