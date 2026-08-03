#!/bin/bash
# Chat Marker installer for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/abdurahhiimov/chat-marker-en/main/install.sh | bash
#
# or, if you already downloaded the folder:  bash install.sh
#
# Needs nothing up front: if there's no python on the mac, it installs its own, into
# its own folder, without brew and without an admin password. Running it again is safe.

set -uo pipefail

REPO_TAR="https://github.com/abdurahhiimov/chat-marker-en/archive/refs/heads/main.tar.gz"
RAW_USERJS="https://raw.githubusercontent.com/abdurahhiimov/chat-marker-en/main/chat-marker.user.js"

APP_HOME="$HOME/.chatmarker"
VISIBLE="$HOME/Documents/Chat Marker"
CLAUDE_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
PY_MIN="3.10"

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m•\033[0m %s\n" "$*"; }
die()  { printf "\n\033[31m✗ %s\033[0m\n\n" "$*"; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This script is for macOS. On Windows and Linux only the browser part works."

printf "\n\033[1mChat Marker\033[0m — install\n"
printf "Takes a minute or two. You won't need an admin password.\n"

# ------------------------------------------------------------------ 0. where the files come from

KIT=""
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  D="$(cd "$(dirname "$SELF")" && pwd)"
  [ -f "$D/chat-marker.user.js" ] && KIT="$D"
fi

CLEANUP=""
if [ -z "$KIT" ]; then
  say "0. Downloading the files"
  TMP="$(mktemp -d)" || die "Couldn't create a temporary folder."
  CLEANUP="$TMP"
  if curl -fsSL "$REPO_TAR" | tar xz -C "$TMP" 2>/dev/null; then
    KIT="$(find "$TMP" -maxdepth 2 -name chat-marker.user.js -print -quit)"
    KIT="$(dirname "$KIT")"
  fi
  [ -n "$KIT" ] && [ -f "$KIT/chat-marker.user.js" ] || die "Couldn't download the files. Check your internet and try again."
  ok "Downloaded"
fi

cleanup() { [ -n "$CLEANUP" ] && rm -rf "$CLEANUP"; }
trap cleanup EXIT

mkdir -p "$APP_HOME"

# ------------------------------------------------------------------ 1. python

say "1. Python"

py_ok() { [ -x "$1" ] && "$1" -c 'import sys;sys.exit(0 if sys.version_info>=(3,10) else 1)' >/dev/null 2>&1; }

PY=""
# We only touch the system python3 if the developer tools are already installed:
# otherwise /usr/bin/python3 is a stub that will silently open the Xcode installer.
if xcode-select -p >/dev/null 2>&1; then
  SYS="$(command -v python3 2>/dev/null || true)"
  py_ok "$SYS" && PY="$SYS"
fi
if [ -z "$PY" ]; then
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$APP_HOME/python/bin/python3"; do
    if py_ok "$c"; then PY="$c"; break; fi
  done
fi

if [ -n "$PY" ]; then
  ok "Found python: $("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])') ($PY)"
else
  warn "No python — installing my own, into $APP_HOME, nothing in the system is affected"
  UV="$APP_HOME/bin/uv"
  if [ ! -x "$UV" ]; then
    curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR="$APP_HOME/bin" UV_NO_MODIFY_PATH=1 sh >/dev/null 2>&1
  fi
  [ -x "$UV" ] || die "Couldn't download the python installer.

Check your internet and run it again. If that doesn't help, install python by hand
from python.org (the 'Download for macOS' button), then start the install over."

  # Keep python inside our own folder: uninstalling wipes it all in one move
  # and doesn't touch anything system-wide.
  export UV_PYTHON_INSTALL_DIR="$APP_HOME/python"
  "$UV" python install 3.12 >/dev/null 2>&1
  PY="$("$UV" python find 3.12 2>/dev/null || true)"
  if ! py_ok "$PY"; then
    for c in "$APP_HOME"/python/*/bin/python3; do py_ok "$c" && PY="$c" && break; done
  fi
  py_ok "$PY" || die "Python downloaded but won't run. Send me the output of this command:
    $UV python install 3.12"
  ok "Python 3.12 installed (for Chat Marker only, the system one is untouched)"
fi

# ------------------------------------------------------------------ 2. environment

say "2. Working environment"

cp "$KIT/scripts/library.py"        "$APP_HOME/" || die "Couldn't copy library.py"
cp "$KIT/scripts/highlights_mcp.py" "$APP_HOME/"
cp "$KIT/scripts/sync-downloads.sh" "$APP_HOME/"
cp "$KIT/scripts/fix-agent.sh"      "$APP_HOME/"
cp "$KIT/scripts/diagnose-agent.sh" "$APP_HOME/"
chmod +x "$APP_HOME"/*.sh

VPY="$APP_HOME/venv/bin/python"
if [ ! -x "$VPY" ]; then
  "$PY" -m venv "$APP_HOME/venv" >/dev/null 2>&1 || die "Couldn't create the environment in $APP_HOME/venv"
fi
"$APP_HOME/venv/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1

# Not everyone has Claude Desktop — we only pull mcp in if it's really needed.
HAS_CLAUDE=""
if [ -d "/Applications/Claude.app" ] || [ -d "$HOME/Applications/Claude.app" ] \
   || [ -d "$HOME/Library/Application Support/Claude" ]; then
  HAS_CLAUDE="yes"
fi

DEPS="openpyxl python-docx"
# mcp 2.x moved the API (mcp.server.fastmcp is gone) — we stay on 1.x,
# otherwise the server won't start on a single fresh install.
MCP_PIN=""
[ -n "$HAS_CLAUDE" ] && MCP_PIN="mcp[cli]>=1.2,<2"
# shellcheck disable=SC2086
if "$APP_HOME/venv/bin/pip" install --quiet $DEPS ${MCP_PIN:+"$MCP_PIN"} >/dev/null 2>&1; then
  ok "Libraries installed ($DEPS${MCP_PIN:+ $MCP_PIN})"
else
  warn "Not everything installed. The spreadsheet and the .docx files may not build."
  warn "By hand: $APP_HOME/venv/bin/pip install $DEPS ${MCP_PIN:+'$MCP_PIN'}"
fi

# ------------------------------------------------------------------ 3. where the library lives

say "3. Library folder"

ROOT="${CHATMARKER_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(cd "$APP_HOME" && "$VPY" -c 'from library import find_drive_root; print(find_drive_root())' 2>/dev/null)"
fi
if [ -z "$ROOT" ]; then
  ROOT="$HOME/Documents/AI Highlights"
  warn "Couldn't find Google Drive — the library will sit locally:"
  warn "$ROOT"
  warn "Install Drive later and just run the install again, everything moves over."
else
  ok "Library: $ROOT"
fi
printf '%s\n' "$ROOT" > "$APP_HOME/root.txt"

if CHATMARKER_ROOT="$ROOT" "$VPY" "$APP_HOME/library.py" --no-ingest >/dev/null 2>&1; then
  ok "Folder structure created"
else
  warn "Couldn't create the structure — the library will build on the first export"
fi

# ------------------------------------------------------------------ 4. the visible folder

say "4. The 'Chat Marker' folder in Documents"

mkdir -p "$VISIBLE"
cp "$KIT/chat-marker.user.js" "$VISIBLE/"
cp "$KIT/Highlights Viewer.html" "$VISIBLE/" 2>/dev/null
cp "$KIT/docs/Chat Marker — manual.html" "$VISIBLE/" 2>/dev/null
cp "$KIT/chat-marker.user.js" "$APP_HOME/"

cat > "$VISIBLE/Read me.txt" <<EOF
Chat Marker
===========

Highlights Viewer.html
    Double-click it. Drag highlights.json from Downloads inside —
    you'll see every highlight, with search and filters. Needs nothing.

Chat Marker — manual.html
    Double-click it. The long version: what it can do, how to use it.

chat-marker.user.js
    The browser script itself. Installed through Tampermonkey,
    see the manual, the section on installing.

Library: $ROOT
Service folder: $APP_HOME
Update: bash $APP_HOME/update.sh
Remove: bash $APP_HOME/uninstall.sh
EOF
ok "$VISIBLE"

# ------------------------------------------------------------------ 5. Claude Desktop

say "5. Claude Desktop"

if [ -n "$HAS_CLAUDE" ]; then
  mkdir -p "$(dirname "$CLAUDE_CFG")"
  [ -f "$CLAUDE_CFG" ] && cp "$CLAUDE_CFG" "$CLAUDE_CFG.backup-$(date +%Y%m%d-%H%M%S)"
  ROOT="$ROOT" APP_HOME="$APP_HOME" CLAUDE_CFG="$CLAUDE_CFG" HOME_DIR="$HOME" \
  "$VPY" <<'PYEOF'
import json, os
from pathlib import Path

cfg_path = Path(os.environ["CLAUDE_CFG"])
app, root, home = os.environ["APP_HOME"], os.environ["ROOT"], os.environ["HOME_DIR"]

cfg = {}
if cfg_path.exists():
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception:
        print("  • can't read the old config, writing a new one (backup is next to it)")
if not isinstance(cfg, dict):
    cfg = {}

cfg.setdefault("mcpServers", {})

# We keep the user's own paths from the previous config instead of wiping them.
# We drop only the Inbox of an old root (after the library moves it would
# cause a double ingest) and duplicates of the required paths.
required = [f"{root}/00 Inbox", f"{home}/Downloads"]
old_env = (cfg["mcpServers"].get("highlights") or {}).get("env") or {}
extras = []
for p in (old_env.get("HIGHLIGHTS_PATH") or "").split(":"):
    p = p.strip()
    if not p or p in required or p in extras:
        continue
    if p.endswith("/00 Inbox"):
        continue
    extras.append(p)

cfg["mcpServers"]["highlights"] = {
    "command": f"{app}/venv/bin/python",
    "args": [f"{app}/highlights_mcp.py"],
    "env": {
        "HIGHLIGHTS_PATH": ":".join(required + extras),
        "CHATMARKER_ROOT": root,
    },
}
cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
tail = f" (+ your paths: {', '.join(extras)})" if extras else ""
print(f"  \033[32m✓\033[0m The highlights server is registered, other people's servers untouched{tail}")
PYEOF
else
  warn "Claude Desktop isn't installed — skipping."
  warn "Install it later (claude.ai/download) and run the install again."
fi

# ------------------------------------------------------------------ 6. auto-build

say "6. Auto-build on export"

if bash "$APP_HOME/fix-agent.sh" >/dev/null 2>&1; then
  ok "Background agent installed (you grant it access at the end, see below)"
else
  warn "The agent didn't take — no big deal, the library builds when you ask Claude"
fi

# ------------------------------------------------------------------ 7. hotkey

say "7. Capture from any app (PDF, Word, Preview, the Claude desktop app)"

if [ -d "/Applications/Hammerspoon.app" ] || [ -d "$HOME/Applications/Hammerspoon.app" ]; then
  mkdir -p "$HOME/.hammerspoon"
  cp "$KIT/extras/hammerspoon/chatmarker.lua" "$HOME/.hammerspoon/chatmarker.lua" 2>/dev/null
  INIT="$HOME/.hammerspoon/init.lua"
  touch "$INIT"
  grep -q 'chatmarker' "$INIT" || printf '\nrequire("chatmarker")\n' >> "$INIT"
  ok "Hammerspoon configured — open it and hit Reload Config"
  warn "It'll ask for Accessibility on its own — without that the hotkeys stay silent"
else
  warn "Hammerspoon isn't installed. That's not a detail: a PDF in the browser can't"
  warn "be selected at all (Chrome has no text layer there), and work documents are"
  warn "exactly that — PDF and Word. Hammerspoon covers them with one hotkey, ⌃⌥⌘1…4."
  echo "     Install: https://www.hammerspoon.org (Download button, drag into Applications)"
  echo "     Then once more:  bash ~/.chatmarker/update.sh  — the config writes itself"
fi

# ------------------------------------------------------------------ 8. update and uninstall

cp "$KIT/scripts/uninstall.sh" "$APP_HOME/uninstall.sh" 2>/dev/null
cat > "$APP_HOME/update.sh" <<EOF
#!/bin/bash
# Updates Chat Marker to the latest version.
curl -fsSL https://raw.githubusercontent.com/abdurahhiimov/chat-marker-en/main/install.sh | bash
EOF
chmod +x "$APP_HOME/update.sh" "$APP_HOME/uninstall.sh" 2>/dev/null

# ------------------------------------------------------------------ wrap-up

cat <<EOF

────────────────────────────────────────────────────────────
Done. Only the browser is left — that part is by hand, one minute.

1. Install Tampermonkey:  https://tampermonkey.net
   (Chrome button → Install → Add extension)

2. Turn on developer mode for it:
   chrome://extensions → top right corner → 'Developer mode'
   Without it Chrome won't let the extension run scripts.

3. Install the script itself — open the link, Tampermonkey will offer to:
   $RAW_USERJS
   Hit 'Install'.

4. Go to claude.ai or any article and reload the page.
   A round button appears in the bottom right. Select text with the mouse —
   a panel with colors pops up.
EOF

if [ -n "$HAS_CLAUDE" ]; then
cat <<EOF

5. Restart Claude Desktop with Cmd+Q (closing the window isn't enough).
   Check it: ask 'show me the stats on my highlights'.

6. To have exports travel into the library on their own:
   System Settings → Privacy & Security →
   Full Disk Access → '+' → Cmd+Shift+G → ~/Applications
   → pick 'ChatMarker Sync'. Skip it and it still works,
   the build just happens the moment you ask Claude.
EOF
fi

cat <<EOF

Your folder:  $VISIBLE
Library:      $ROOT
────────────────────────────────────────────────────────────

EOF

open "$VISIBLE" 2>/dev/null
exit 0
