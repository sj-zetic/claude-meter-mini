#!/bin/bash
# Build ClaudeUsage, assemble the .app bundle, ad-hoc sign, install to
# ~/Applications, and launch it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

LABEL="com.seongjun.claudeusage"
RELOGIN_LABEL="com.seongjun.claudeusage.relogin"

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

# Keep-signed-in: a second LaunchAgent re-logs-in every 4h (and at login) via
# the desktop session, so the token endpoint's rate-limited refresh is never
# used. The widget ALSO kicks this job the moment it sees the token expiring
# (see UsageFetcher.kickReloginIfDue), which covers wake-from-sleep. Requires
# being signed into the Claude desktop app.
echo "==> installing relogin LaunchAgent (keeps the token fresh, every 4h + on expiry)"
RELOGIN_PLIST="$HOME/Library/LaunchAgents/$RELOGIN_LABEL.plist"
mkdir -p "$HOME/Library/Logs"
cat > "$RELOGIN_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$RELOGIN_LABEL</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO/scripts/relogin.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>14400</integer>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/claudeusage-relogin.out.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/claudeusage-relogin.err.log</string>
</dict>
</plist>
PLISTEOF
chmod +x "$REPO/scripts/relogin.sh"
launchctl bootout "gui/$(id -u)/$RELOGIN_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$RELOGIN_PLIST"

echo "Done. Crab icon starts at login; the token auto-refreshes via re-login (every 4h + on expiry)."
echo "(On another machine, edit EMAIL in scripts/relogin.sh and sign into the Claude desktop app.)"
