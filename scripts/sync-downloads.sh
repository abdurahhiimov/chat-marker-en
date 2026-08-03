#!/bin/bash
# Takes a fresh export from ~/Downloads into Google Drive and rebuilds the library.
# Runs automatically (launchd watches the downloads folder), but you can run it by hand.

set -uo pipefail

APP_HOME="${CHATMARKER_HOME:-$HOME/.chatmarker}"
PY="$APP_HOME/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

# library root — the same one the install picked
if [ -z "${CHATMARKER_ROOT:-}" ] && [ -s "$APP_HOME/root.txt" ]; then
  CHATMARKER_ROOT="$(head -n1 "$APP_HOME/root.txt")"
  export CHATMARKER_ROOT
fi

# is there anything to move at all — so we don't wake the build on every sneeze in downloads.
# Subfolders count too (one level): exports often land in ~/Downloads/Highlights.
# No arrays: the stock bash on a mac is 3.2, and an empty array under set -u blows up there.
PENDING=0
for f in "$HOME/Downloads"/highlights*.json \
         "$HOME/Downloads"/*/highlights*.json; do
  [ -e "$f" ] && PENDING=1
done
[ "$PENDING" -eq 0 ] && exit 0

out="$("$PY" "$APP_HOME/library.py" 2>&1)"
echo "$out"

if echo "$out" | grep -q "built:"; then
  count="$(echo "$out" | sed -n 's/.*built: \([0-9]*\) highlights.*/\1/p')"
  osascript -e "display notification \"${count:-?} highlights in the library\" with title \"Chat Marker\"" 2>/dev/null || true
fi

exit 0
