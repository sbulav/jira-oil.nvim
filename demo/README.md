# Demo Recording Setup

This folder contains everything needed to create demo videos/GIFs of jira-oil.nvim
without exposing real Jira data.

## Files

| File | Purpose |
|------|---------|
| `jira-demo` | Mock jira-cli script that returns fake data |
| `demo.lua` | Neovim config that uses the mock CLI |
| `record.tape` | VHS recording script (automated) |
| `record-asciinema.sh` | Asciinema recording script (manual) |

## Quick Start

```bash
# Enter reproducible demo environment (recommended)
nix develop

# Test the mock CLI
./demo/jira-demo issue list -q "sprint in openSprints()" --raw

# Test the demo in Neovim
nvim -u demo/demo.lua

# Record the demo GIF
vhs demo/record.tape

# or via flake app
nix run .#record-demo
```

## Recording Methods

### Option 1: VHS (Recommended for automated recordings)

[VHS](https://github.com/charmbracelet/vhs) creates recordings from scripts:

```bash
# Enter the nix shell with all recording dependencies
nix develop

# Run recording
vhs demo/record.tape
```

Output: `demo/jira-oil-demo.gif`

### Option 2: Asciinema (For manual control)

[Asciinema](https://asciinema.org/) records your terminal session:

```bash
# Install with Nix
nix shell nixpkgs#asciinema

# Run recording script
./demo/record-asciinema.sh
```

Or manually:

```bash
# Record
asciinema rec demo/demo.cast --command "nvim -u demo/demo.lua"

# Convert to GIF (optional; requires agg)
agg --font-family "JetBrains Mono" --font-size 16 demo/demo.cast demo/jira-oil-demo.gif
```

### Option 3: Terminalizer (For manual control)

```bash
# Install
npm install -g terminalizer

# Record interactively
terminalizer record demo/recording

# Render to GIF
terminalizer render demo/recording -o demo/jira-oil-demo.gif
```

## Customizing the Demo Data

Edit `demo/jira-demo` to change the fake issues:

```bash
# Add more issues to fake_sprint_issues()
# Modify issue details in fake_issue_view()
# Add new components in demo.lua's create.available_components
```

The mock CLI is intentionally static and fake so no real project names,
people, ticket titles, or internal links appear in recordings.

## Color Schemes

The demo config tries these colorschemes in order:
1. tokyonight
2. catppuccin
3. gruvbox

Install one before recording for best results:

```bash
# Lazy.nvim
:{ "folke/tokyonight.nvim" }
:{ "catppuccin/nvim" }
:{ "ellisonleao/gruvbox.nvim" }
```

## Tips for Good Recordings

1. **Use a Nerd Font** - Required for status/type icons
2. **Disable mouse** - Already set in demo.lua
3. **Keep it short** - 10-15 seconds ideal for GitHub README
4. **Show key features**:
   - List view with sprint/backlog sections
   - Opening an issue (Enter)
   - Inline editing status
   - Creating new issue (Ctrl+c)
   - Help popup (g?)

## Troubleshooting

### "bad interpreter: No such file or directory"
The script uses `#!/usr/bin/env bash` for portability. If it still fails:

```bash
# Check your bash location
which bash
# Edit the shebang line in jira-demo
```

### Icons show as boxes
Install a Nerd Font:
```bash
# NixOS
nix-shell -p nerd-fonts.jetbrains-mono

# Or download from https://www.nerdfonts.com/
```

### GIF is too large
Reduce dimensions and FPS:
```bash
agg --font-size 14 --fps 15 demo/demo.cast demo/jira-oil-demo.gif
```

### Recording is too slow/fast
Edit timing in `record.tape` or record manually with asciinema.
