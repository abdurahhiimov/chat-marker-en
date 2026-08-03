#!/bin/bash
# Works out why the background agent isn't moving exports out of downloads.
# Breaks nothing, only reads and tries things. Run it with:
#     bash ~/Downloads/diagnose-agent.sh

set -uo pipefail

APP_HOME="$HOME/.chatmarker"
LABEL="com.chatmarker.sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

hdr()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
info() { printf "  \033[90m·\033[0m %s\n" "$*"; }

VERDICT=""

printf "\n\033[1mChat Marker — why exports aren't moving\033[0m\n"

# ---------------------------------------------------------------- 1. files

hdr "1. What's in place"

for f in "$APP_HOME/library.py" "$APP_HOME/highlights_mcp.py" "$APP_HOME/venv/bin/python" "$APP_HOME/root.txt"; do
  [ -e "$f" ] && ok "$(basename "$f")" || bad "missing: $f"
done

if [ -f "$APP_HOME/root.txt" ]; then
  ROOT="$(cat "$APP_HOME/root.txt")"
  info "library: $ROOT"
  [ -d "$ROOT" ] && ok "the library folder exists" || bad "there's no library folder"
fi

hdr "2. What's sitting in downloads"
PENDING=0
for f in "$HOME/Downloads"/highlights*.json; do
  [ -e "$f" ] || continue
  PENDING=$((PENDING + 1))
  ok "$(basename "$f") ($(stat -f%z "$f" 2>/dev/null || echo "?") bytes)"
done
[ "$PENDING" -eq 0 ] && info "no exports in ~/Downloads — nothing to move"

# ---------------------------------------------------------------- 3. the agent

hdr "3. The launchd agent"

if [ -f "$PLIST" ]; then
  ok "plist is in place"
else
  bad "plist wasn't created — install.sh never got this far"
  VERDICT="no-plist"
fi

if ! command -v launchctl >/dev/null 2>&1; then
  bad "launchctl isn't available — is this really macOS?"
  PRINT="Could not find service"
else
  PRINT="$(launchctl print "gui/$UID_NUM/$LABEL" 2>&1)"
fi
if echo "$PRINT" | grep -q "Could not find service"; then
  bad "the agent is NOT loaded into launchd"
  [ -z "$VERDICT" ] && VERDICT="not-loaded"
else
  ok "the agent is registered"
  STATE="$(echo "$PRINT"  | awk -F' = ' '/^\tstate/ {print $2; exit}')"
  LASTEXIT="$(echo "$PRINT" | awk -F' = ' '/last exit code/ {print $2; exit}')"
  RUNS="$(echo "$PRINT" | awk -F' = ' '/runs/ {print $2; exit}')"
  info "state: ${STATE:-unknown}, runs: ${RUNS:-0}, last exit code: ${LASTEXIT:-none}"
  if [ "${RUNS:-0}" = "0" ]; then
    bad "the agent has never run — macOS isn't waking it"
    [ -z "$VERDICT" ] && VERDICT="never-ran"
  fi
  case "${LASTEXIT:-}" in
    ""|0) ;;
    *) bad "the last run ended with an error ($LASTEXIT)"; [ -z "$VERDICT" ] && VERDICT="exit-error" ;;
  esac
fi

hdr "4. The agent log"
if [ -s "$APP_HOME/sync.log" ]; then
  info "last lines:"
  tail -8 "$APP_HOME/sync.log" | sed 's/^/     /'
else
  info "the log is empty or missing — the agent wrote nothing"
fi

# ---------------------------------------------------------------- 5. by hand

hdr "5. Trying the same thing by hand"

PY="$APP_HOME/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

MANUAL="$("$PY" "$APP_HOME/library.py" 2>&1)"
MANUAL_CODE=$?
echo "$MANUAL" | sed 's/^/     /'

if [ $MANUAL_CODE -eq 0 ]; then
  ok "by hand it all works"
  if echo "$MANUAL" | grep -q "exports taken in"; then
    ok "and the file just moved into the library"
  fi
else
  bad "it fails by hand too — so it's not about permissions, it's the script itself"
  VERDICT="script-broken"
fi

# ---------------------------------------------------------------- verdict

hdr "Verdict"

case "$VERDICT" in
  script-broken)
    echo "  The problem is in the script, not the system. Send me the whole of section five."
    ;;
  no-plist|not-loaded)
    echo "  The agent isn't registered with the system. Fixed by reloading the agent —"
    echo "  run fix-agent.sh, it rebuilds it the modern way."
    ;;
  never-ran|exit-error)
    echo "  The agent exists but either doesn't wake up or crashes. Two likely reasons:"
    echo "    · macOS never allowed the background item (Settings → General → Login Items)"
    echo "    · the agent has no access to the Downloads folder (that's Full Disk Access)"
    echo "  Run fix-agent.sh — it rebuilds the agent so the permission can be granted"
    echo "  to one understandable line instead of to all of bash at once."
    ;;
  *)
    if [ "$PENDING" -eq 0 ] && [ -n "$(ls -A "${ROOT:-/nonexistent}/00 Inbox" 2>/dev/null)" ]; then
      echo "  Looks fine: downloads are empty, the library is filled."
    else
      echo "  I don't see anything obviously broken. Send me the whole output and we'll dig in."
    fi
    ;;
esac

echo
