Require jira-oil.nvim

# VHS Recording Script
# =====================
# Install vhs: https://github.com/charmbracelet/vhs
# Run: vhs demo/record.tape

Output demo/jira-oil-demo.gif

Set FontSize 14
Set FontFamily "JetBrains Mono Nerd Font"
Set Padding 10
Set Width 1000
Set Height 600
Set Theme "Catppuccin Mocha"

# Hide cursor for cleaner recording
Hide
Type "nvim -u demo/demo.lua"
Enter
Sleep 1500ms

# Wait for buffer to load
Sleep 1000ms

Show

# Demo: View sprint and backlog issues
# =====================================

# Navigate through the list
Sleep 500ms
Type "jjj"
Sleep 300ms

# Open an issue (DEMO-101)
Type "Enter"
Sleep 800ms

# View the issue details
Sleep 1000ms

# Go back to list
Type "Escape"
Type ":q"
Enter
Sleep 500ms

# Demo: Edit status inline
# ========================

# Go to DEMO-102 line
Type "jj"
Sleep 200ms

# Edit status (simulate changing "To Do" to "In Progress")
Type "ww"
Sleep 200ms
Type "cw"
Sleep 100ms
Type "In Progress"
Escape
Sleep 300ms

# Show the [draft] marker appears
Sleep 500ms

# Demo: Save changes
# ==================

Type "Ctrl+s"
Sleep 500ms

# Confirm save (Y in floating window)
Type "Y"
Sleep 500ms

# Demo: Create new issue
# ======================

# Open create buffer
Type "Ctrl+c"
Sleep 800ms

# Type a summary
Type "cc"
Sleep 100ms
Type "Add keyboard shortcuts help"
Escape
Sleep 300ms

# Close without saving
Type "Ctrl+q"
Sleep 300ms

# Demo: Show help
# ================

Type "g?"
Sleep 800ms

# Close help
Type "q"
Sleep 300ms

# Demo: Refresh
# =============

Type "Alt+r"
Sleep 500ms

# Final view
Sleep 1000ms

# Quit
Type "Ctrl+q"
Sleep 200ms
Type ":q!"
Enter
Sleep 500ms
