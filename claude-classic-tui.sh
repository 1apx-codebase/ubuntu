#!/usr/bin/env bash
# Switch Claude Code to its classic interface so the terminal's own mouse
# selection and copy work. Run with --revert to go back to fullscreen.
set -euo pipefail

SETTINGS=/root/.claude/settings.json   # used by `sudo claude`

if [[ ! -f "$SETTINGS" ]]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

cp -a "$SETTINGS" "$SETTINGS.bak-$(date +%F-%H%M%S)"

f=$(mktemp)
if [[ "${1:-}" == "--revert" ]]; then
  jq 'del(.tui)' "$SETTINGS" > "$f"
else
  jq '.tui = "default"' "$SETTINGS" > "$f"
fi
cat "$f" > "$SETTINGS"
rm -f "$f"

# Verify
jq . "$SETTINGS"
