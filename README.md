# jira-oil.nvim

Edit your Jira backlog and sprints exactly like a regular Neovim text buffer. 

Inspired by the incredible [oil.nvim](https://github.com/stevearc/oil.nvim), this plugin gives you a virtual "filesystem" for your Jira tasks. See your issues in a list, edit fields directly in the buffer, and press `:w` to dispatch the changes. No more clunky UIs or context switching.

## Features

- **Buffer-as-Jira**: View your current sprint or backlog as a tabular list in a normal Neovim buffer.
- **Inline Editing**: Change statuses, reassign tasks, or edit summaries just by editing text.
- **Batch Mutations**: Make multiple changes at once, press `:w`, and confirm them in a floating window before execution.
- **Fast Creation**: Add a new line in the list buffer to create a task instantly.
- **Scratch Buffers**: Hit `<CR>` to open a full markdown scratch buffer with YAML frontmatter for detailed task editing and commenting.
- **Sprint Management**: Delete a line (`dd`) to move an issue between your sprint and backlog.

## Prerequisites

This plugin acts as a Neovim UI wrapper around the official **Jira CLI**.

1. Install [ankitpokhrel/jira-cli](https://github.com/ankitpokhrel/jira-cli).
2. Authenticate and configure it (`jira init`). 
3. Ensure the `jira` command works from your terminal.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-username/jira-oil.nvim",
  dependencies = {
    -- Any dependencies here (e.g. plenary if you decide to add it later)
  },
  config = function()
    require("jira-oil").setup({
      defaults = {
        -- Set your default project prefix here
        project = "PROJ", 
      }
    })
  end
}
```

## Quick Start

1. Open Neovim and run `:JiraOil`. This opens your current active sprint in a buffer.
2. Run `:JiraOil backlog` to see your project's backlog.
3. Move your cursor around. Edit the text in the "Status" or "Assignee" columns.
4. Press `:w` (or `<C-s>`). A floating window will appear showing the exact API mutations you are about to trigger.
5. Press `Y` to confirm and execute the changes.

## Usage Guide

### The List Buffer (`jira-oil://sprint` or `jira-oil://backlog`)

When you open a JiraOil buffer, you get a fixed-column layout:
```text
PROJ-101 │ In Progress │ Task │ me   │ Fix the login bug
PROJ-102 │ To Do       │ Bug  │ john │ Update README
```

- **Edit an issue:** Just change the text. If you change "To Do" to "In Progress", the plugin will queue a status transition.
- **Create an issue inline:** Press `o` to create a new line. Leave the key column blank and type your summary at the end. Saving will create the task.
- **Move to Backlog/Sprint:** Pressing `dd` removes the line from the current view. If you are in the sprint, saving will move it to the backlog. If you are in the backlog, saving will add it to the active sprint.

### The Scratch Buffer (`jira-oil://issue/PROJ-101`)

For longer descriptions or to view full task details, press `<CR>` while hovering over an issue in the list buffer. This opens a Markdown buffer:

```markdown
---
Project: PROJ
Type: Task
Status: To Do
Assignee: me
---
# Summary
Fix the login bug

# Description
When the user clicks login, it crashes...
```

Edit the frontmatter or the markdown body, then save (`:w`) to push the changes.

To create a new task with full details, press `c` in the list buffer to open an empty scratch buffer (`jira-oil://issue/new`).

## Default Keymaps

### In the List Buffer
| Key | Action |
|-----|--------|
| `<CR>` | Open issue under cursor in Scratch Buffer |
| `c` | Create new issue (opens empty Scratch Buffer) |
| `<C-s>` | Save buffer and trigger mutation confirmation |
| `<M-r>` | Force refresh data from Jira |
| `q` | Close the buffer |

### In the Scratch Buffer
| Key | Action |
|-----|--------|
| `<C-s>` | Save and push changes to Jira |
| `q` | Close the buffer |

## Configuration

You can customize columns, default behaviors, and keymaps. Here is the default configuration:

```lua
require("jira-oil").setup({
  cli = {
    cmd = "jira",
    timeout = 10000, -- 10 seconds
  },
  view = {
    -- Define columns and fixed widths. The last column scales automatically.
    columns = {
      { name = "key", width = 12 },
      { name = "status", width = 15 },
      { name = "type", width = 10 },
      { name = "assignee", width = 15 },
      { name = "summary" },
    },
    default_sort = "key",
  },
  keymaps = {
    open = "<CR>",
    create = "c",
    refresh = "<M-r>",
    close = "q",
    save = "<C-s>",
  },
  -- Default values used when creating new issues
  defaults = {
    project = vim.env.JIRA_PROJECT or "",
    assignee = vim.env.JIRA_ASSIGNEE or "me",
    issue_type = "Task",
  },
})
```

## Troubleshooting

### "Invalid URI" or missing commands
Ensure you have run `require("jira-oil").setup()` in your `init.lua`. This registers the custom `jira-oil://` protocol handler.

### "Failed to create issue"
Check if your `jira-cli` configuration is correct by running `jira issue list` in your terminal. Ensure your `project` is correctly set in the plugin config.

## License
MIT
