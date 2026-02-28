Require nvim
Require vhs

Output demo/jira-oil-demo.gif

Set Shell "bash"
Set FontSize 18
Set FontFamily "JetBrains Mono"
Set Padding 12
Set Width 1300
Set Height 650
Set Theme "Catppuccin Mocha"
Set TypingSpeed 70ms

Hide
Type "nvim -u demo/demo.lua"
Enter
Show

# Let jira-oil open and render sprint + backlog
Sleep 3200ms

# Open first issue in scratch view
Type "j"
Sleep 600ms
Enter
Sleep 2800ms

# Close scratch and return to list
Ctrl+Q
Sleep 2500ms

# Bulk change assignee for multiple issues in one command
Type ":%s/Alice Chen/Sam Rivera/g"
Enter
Sleep 2400ms

# Go to second sprint issue and edit status inline
Type "j"
Sleep 550ms
Type ":s/To Do/In Progress/"
Enter
Sleep 1800ms

# Move issue across sections (Sprint -> Backlog)
Type "dd"
Sleep 1800ms

# Save list changes and confirm mutation dialog
Ctrl+S
Sleep 3200ms
Type "Y"
Sleep 2600ms

# Create a new issue from scratch buffer
# Open create issue scratch buffer (more deterministic than Ctrl+C in tapes)
Type ":e jira-oil://issue/new"
Enter
Sleep 2200ms
Type "gg7j0"
Sleep 550ms
Type "iShip polished README demo recording"
Escape
Sleep 1200ms
Ctrl+S
Sleep 3400ms
Type ":e jira-oil://all"
Enter
Sleep 2200ms

# Show keymap help popup
Type "g?"
Sleep 2000ms
Type "q"
Sleep 1100ms

# Exit Neovim
Ctrl+Q
Sleep 250ms
Type ":qa!"
Enter
Sleep 500ms
