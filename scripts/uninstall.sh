#!/bin/bash
# Removes everything install.sh put in place. Does NOT touch the highlights database.
set -uo pipefail

APP_HOME="$HOME/.chatmarker"
PLIST="$HOME/Library/LaunchAgents/com.chatmarker.sync.plist"
CLAUDE_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

echo "Removing the agent that watches downloads…"
launchctl bootout "gui/$(id -u)/com.chatmarker.sync" >/dev/null 2>&1
launchctl unload "$PLIST" >/dev/null 2>&1
rm -f "$PLIST"
rm -rf "$HOME/Applications/ChatMarker Sync.app"

echo "Removing the server from the Claude Desktop config…"
# Our own python is more reliable than the system one: on a clean mac python3 is
# a stub that opens the Xcode installer instead of doing any work.
PY="$APP_HOME/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null || true)"

if [ -f "$CLAUDE_CFG" ] && [ -z "$PY" ]; then
  echo "  ! no python — remove \"highlights\" from the config by hand:"
  echo "    $CLAUDE_CFG"
elif [ -f "$CLAUDE_CFG" ]; then
  cp "$CLAUDE_CFG" "$CLAUDE_CFG.backup-$(date +%Y%m%d-%H%M%S)"
  "$PY" - "$CLAUDE_CFG" <<'PYEOF'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    cfg = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    sys.exit(0)
cfg.get("mcpServers", {}).pop("highlights", None)
p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
print("  done")
PYEOF
fi

echo "Removing the line from the Hammerspoon config…"
INIT="$HOME/.hammerspoon/init.lua"
if [ -f "$INIT" ]; then
  # grep -v returns 1 if no lines are left — the file still has to be replaced
  grep -v 'require("chatmarker")' "$INIT" > "$INIT.tmp" || true
  mv "$INIT.tmp" "$INIT"
fi
rm -f "$HOME/.hammerspoon/chatmarker.lua"

echo "Deleting ~/.chatmarker…"
rm -rf "$APP_HOME"

cat <<EOF

Done. Removed: the service folder, our own python, the background agent, the entry in the Claude config.

Left for you, if you want it gone:
  · delete the script in Tampermonkey (extension icon → Dashboard)
  · the 'Documents/Chat Marker' folder — viewer and manual, I don't touch it
  · the highlights library is still there too: 'AI Highlights'

EOF
