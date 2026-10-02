local t = require("minitest")
local view = require("jira-oil.view")
local config = require("jira-oil.config")
local cli = require("jira-oil.cli")
local h = require("helpers")

local function check_visible_list(target, key_width, expected_width)
  local options = vim.deepcopy(config.options)
  options.defaults.project = "PROJ"
  options.view.show_winbar = true
  options.view.key_width = key_width

  h.stub(config, "options", options, function()
    h.stub(cli, "get_filtered_issues", function(section, _, callback)
      callback({ {
        key = section == "sprint" and "PROJ-1" or "PROJ-2",
        fields = { status = { name = "Open" }, summary = "Test issue" },
      } })
    end, function()
      local previous_buf = vim.api.nvim_get_current_buf()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(buf)
      local ok, err = pcall(function()
        view.open(buf, "jira-oil://" .. target)

        local winbar = vim.wo.winbar
        local project_text = "PROJ" .. string.rep(" ", expected_width - 4)
        t.ok(winbar:find("%#JiraOilWinbarProject#" .. project_text .. " %*", 1, true),
          "winbar project should use the key column width")
        t.ok(winbar:find(target == "all" and "2 issues" or "1 issue", 1, true),
          "winbar should show the issue count")
        t.eq(view.get_key_at_line(buf, 1), target == "backlog" and "PROJ-2" or "PROJ-1")
        t.ok(vim.fn.maparg("<CR>", "n") ~= "", "list keymaps should be installed")
        t.ok(not vim.bo[buf].modified)
      end)
      vim.api.nvim_set_current_buf(previous_buf)
      view.cache[buf] = nil
      view.open_seq[buf] = nil
      view.mark_keys[buf] = nil
      vim.api.nvim_buf_delete(buf, { force = true })
      if not ok then
        error(err, 0)
      end
    end)
  end)
end

t.test("view: opening a visible combined list renders the winbar", function()
  check_visible_list("all", 12, 12)
end)

t.test("view: sprint winbar respects a custom key width", function()
  check_visible_list("sprint", 8, 8)
end)

t.test("view: backlog winbar defaults to 12 when key width is absent", function()
  check_visible_list("backlog", nil, 12)
end)
