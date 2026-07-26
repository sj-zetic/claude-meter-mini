#!/bin/bash
# Build ClaudeUsage, assemble the .app bundle, ad-hoc sign, install to
# ~/Applications, and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.seongjun.claudeusage"

# Stop any LaunchAgent-managed instance FIRST, otherwise crash-restart would
# respawn the app mid-rebuild.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage >/dev/null 2>&1 || true
sleep 0.5

echo "==> swift build -c release"
swift build -c release

APP="$HOME/Applications/ClaudeUsage.app"
echo "==> assembling $APP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeUsage "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

# Always-on: a LaunchAgent starts it at login and restarts it if it crashes
# (but honors an intentional Quit — restart only on non-zero exit).
echo "==> installing LaunchAgent (start at login + crash-restart)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$APP/Contents/MacOS/ClaudeUsage"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$BIN</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Done. Look for the crab icon in the menu bar (starts automatically at login)."
