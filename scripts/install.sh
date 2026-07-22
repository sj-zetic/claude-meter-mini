#!/bin/bash
# Build ClaudeUsage, assemble the .app bundle, ad-hoc sign, install to
# ~/Applications, and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

APP="$HOME/Applications/ClaudeUsage.app"
echo "==> assembling $APP"
osascript -e 'tell application "ClaudeUsage" to quit' >/dev/null 2>&1 || true
pkill -x ClaudeUsage >/dev/null 2>&1 || true
sleep 0.5

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeUsage "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> launching"
open "$APP"
echo "Done. Look for the gauge icon in the menu bar."
