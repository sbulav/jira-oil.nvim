#!/usr/bin/env bash
# Simple recording script using asciinema + agg (asciinema's GIF converter)
# Usage: ./record-asciinema.sh

set -e

cd "$(dirname "$0")/.."

# Check dependencies
if ! command -v asciinema &>/dev/null; then
  echo "Error: asciinema not found. Install with: nix-shell -p asciinema"
  exit 1
fi

if ! command -v agg &>/dev/null; then
  echo "Warning: agg not found. Will create .cast file only."
  echo "Install agg to convert to GIF: cargo install agg"
fi

CAST_FILE="demo/jira-oil-demo.cast"
GIF_FILE="demo/jira-oil-demo.gif"

echo "Recording demo..."
echo "Press Ctrl+D when done recording."

# Record with custom shell that pre-loads the demo
asciinema rec \
  --command "nvim -u demo/demo.lua" \
  --title "jira-oil.nvim demo" \
  --overwrite \
  "$CAST_FILE"

echo "Recording saved to $CAST_FILE"

if command -v agg &>/dev/null; then
  echo "Converting to GIF..."
  agg \
    --font-family "JetBrains Mono" \
    --font-size 16 \
    --theme catppuccin-mocha \
    --fps 30 \
    "$CAST_FILE" \
    "$GIF_FILE"
  echo "GIF saved to $GIF_FILE"
fi
