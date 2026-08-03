#!/bin/bash
# Rebuilds the background agent so that access to the Downloads folder can be
# granted to one understandable item instead of to all of bash at once.
#
# What it does:
#   1. builds a tiny app, "ChatMarker Sync.app" — all it does is
#      kick off the library build, nothing else;
#   2. signs it locally so the system remembers the permission you granted;
#   3. repoints the launchd agent at that app, the modern way;
#   4. prints what exactly to drag into Full Disk Access.
#
# Run it with: bash fix-agent.sh

set -uo pipefail

APP_HOME="$HOME/.chatmarker"
LABEL="com.chatmarker.sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APPDIR="$HOME/Applications/ChatMarker Sync.app"
EXE="$APPDIR/Contents/MacOS/ChatMarkerSync"
UID_NUM="$(id -u)"

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
die()  { printf "\n\033[31m✗ %s\033[0m\n\n" "$*"; exit 1; }

[ "$(uname)" = "Darwin" ] || die "This script is for macOS."
[ -f "$APP_HOME/library.py" ] || die "Couldn't find ~/.chatmarker/library.py — run install.sh first"

# ---------------------------------------------------------------- 1. the app

say "1. Building the launcher app"

mkdir -p "$APPDIR/Contents/MacOS"

cat > "$APPDIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ChatMarkerSync</string>
    <key>CFBundleIdentifier</key><string>com.chatmarker.sync</string>
    <key>CFBundleName</key><string>ChatMarker Sync</string>
    <key>CFBundleDisplayName</key><string>ChatMarker Sync</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
EOF

TMPBASE="$(mktemp -t chatmarker)"
SRC="$TMPBASE.c"
cat > "$SRC" <<'EOF'
/* Kicks off the library build. Does nothing else.
   The separate binary exists so that macOS grants access to Downloads
   to this app specifically, not to every script on the machine. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    const char *home = getenv("HOME");
    if (home == NULL) return 2;

    /* we take the library root from root.txt — the same one install.sh picked,
       otherwise with two Google accounts the agent and MCP would build different folders */
    char rootfile[1024], rootbuf[1024];
    snprintf(rootfile, sizeof rootfile, "%s/.chatmarker/root.txt", home);
    FILE *rf = fopen(rootfile, "r");
    if (rf) {
        if (fgets(rootbuf, sizeof rootbuf, rf)) {
            rootbuf[strcspn(rootbuf, "\n")] = 0;
            if (rootbuf[0]) setenv("CHATMARKER_ROOT", rootbuf, 0);
        }
        fclose(rf);
    }

    char py[1024], venv[1024], script[1024];
    snprintf(venv,   sizeof venv,   "%s/.chatmarker/venv/bin/python", home);
    snprintf(script, sizeof script, "%s/.chatmarker/library.py",      home);

    if (access(venv, X_OK) == 0) {
        snprintf(py, sizeof py, "%s", venv);
    } else if (access("/opt/homebrew/bin/python3", X_OK) == 0) {
        snprintf(py, sizeof py, "/opt/homebrew/bin/python3");
    } else {
        snprintf(py, sizeof py, "/usr/bin/python3");
    }

    char *args[] = { py, script, "--quiet", NULL };
    pid_t pid;
    if (posix_spawn(&pid, args[0], NULL, NULL, args, environ) != 0) {
        perror("posix_spawn");
        return 3;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 4;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
EOF

COMPILED=0
if command -v clang >/dev/null 2>&1 && clang -O2 -o "$EXE" "$SRC" 2>/dev/null; then
  COMPILED=1
  ok "binary built"
else
  warn "clang isn't available — making the launcher a script instead"
  cat > "$EXE" <<'EOF'
#!/bin/bash
PY="$HOME/.chatmarker/venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
if [ -z "${CHATMARKER_ROOT:-}" ] && [ -s "$HOME/.chatmarker/root.txt" ]; then
  CHATMARKER_ROOT="$(head -n1 "$HOME/.chatmarker/root.txt")"
  export CHATMARKER_ROOT
fi
exec "$PY" "$HOME/.chatmarker/library.py" --quiet
EOF
fi
chmod +x "$EXE"
rm -f "$SRC" "$TMPBASE"

# ---------------------------------------------------------------- 2. signing

say "2. Signing it locally"

if command -v codesign >/dev/null 2>&1 && codesign --force --sign - "$APPDIR" >/dev/null 2>&1; then
  ok "signed (the system will remember the permission you granted)"
else
  warn "signing didn't work — you'll have to grant the permission again if the app gets rebuilt"
fi

# ---------------------------------------------------------------- 3. the agent

say "3. Repointing the agent"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$EXE</string></array>
    <key>WatchPaths</key>
    <array><string>$HOME/Downloads</string></array>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$APP_HOME/sync.log</string>
    <key>StandardErrorPath</key><string>$APP_HOME/sync.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
launchctl unload "$PLIST" >/dev/null 2>&1

if launchctl bootstrap "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1; then
  ok "agent registered"
elif launchctl load "$PLIST" >/dev/null 2>&1; then
  ok "agent registered (the old way)"
else
  warn "launchctl wouldn't take the agent — send me the output of: launchctl print gui/$UID_NUM/$LABEL"
fi

launchctl enable "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
launchctl kickstart -k "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 && ok "kicked off a test run"

# ---------------------------------------------------------------- 4. permissions

say "4. One thing left — grant access, once"

cat <<EOF

  Open:  System Settings → Privacy & Security
         → Full Disk Access

  Hit '+', in the file picker press Cmd+Shift+G and paste the path:

      ~/Applications

  Pick 'ChatMarker Sync' and flip its switch on.

  This app can do exactly one thing: read an export from downloads
  and sort it into folders in Google Drive. There's nothing else in it
  ($([ $COMPILED = 1 ] && echo "fifty-odd lines of C source, compiled just now" || echo "three lines of bash")).

  While you're there, check: Settings → General → Login Items →
  the 'Allow in the Background' section. ChatMarker Sync should be
  switched on there. macOS sometimes adds background items switched off.

EOF

say "5. How to check it worked"

cat <<'EOF'

  Export the .json from the side panel in the browser and wait about ten seconds.
  The file should disappear from downloads, and 'Index.md' in the library folder
  should update. If that didn't happen:

      tail -20 ~/.chatmarker/sync.log

  And send me what's in there.

EOF
