#!/usr/bin/env bash
# Switch Claude Code to its classic interface so the terminal's own mouse
# selection and copy work. Run with --revert to go back to fullscreen.
set -euo pipefail

# user:settings file. root's is used by `sudo claude`.
TARGETS=(
  root:/root/.claude/settings.json
  vaviles:/home/vaviles/.claude/settings.json
)

for t in "${TARGETS[@]}"; do
  owner=${t%%:*}
  settings=${t#*:}

  if [[ ! -f "$settings" ]]; then
    install -d -o "$owner" -g "$owner" "$(dirname "$settings")"
    echo '{}' > "$settings"
    chown "$owner:$owner" "$settings"
  fi

  cp -a "$settings" "$settings.bak-$(date +%F-%H%M%S)"

  # Write through cat so the file keeps its owner and mode
  f=$(mktemp)
  if [[ "${1:-}" == "--revert" ]]; then
    jq 'del(.tui)' "$settings" > "$f"
  else
    jq '.tui = "default"' "$settings" > "$f"
  fi
  cat "$f" > "$settings"
  rm -f "$f"

  # Verify
  echo "$settings"
  jq . "$settings"
done
