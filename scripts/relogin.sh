#!/bin/bash
# Keeps the widget's Keychain credential fresh WITHOUT using the (rate-limited)
# token-refresh endpoint. Runs `claude auth login`, which completes headlessly
# by reusing the signed-in Claude desktop session and writes a fresh ~24h token
# to the "Claude Code-credentials" Keychain item that the widget reads.
#
# Invoked by the com.seongjun.claudeusage.relogin LaunchAgent every ~12h and at
# login. Safe to run manually any time.
set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.nvm/versions/node/*/bin:/usr/bin:/bin"
EMAIL="you@example.com"
LOG="$HOME/Library/Logs/claudeusage-relogin.log"
NPX="$(command -v npx || echo /usr/local/bin/npx)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] relogin start" >> "$LOG"
# stdin from /dev/null: the login reuses the desktop session and completes
# before it would ever prompt for a code, so it never blocks.
"$NPX" -y @anthropic-ai/claude-code auth login --claudeai --email "$EMAIL" < /dev/null >> "$LOG" 2>&1
STATUS=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] relogin exit=$STATUS" >> "$LOG"
exit $STATUS
