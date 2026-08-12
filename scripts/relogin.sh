#!/bin/bash
# Keeps the widget's Keychain credential fresh WITHOUT using the (rate-limited)
# token-refresh endpoint. Runs `claude auth login`, which completes headlessly
# by reusing the signed-in Claude desktop session and writes a fresh ~24h token
# to the "Claude Code-credentials" Keychain item that the widget reads.
#
# Invoked by the com.seongjun.claudeusage.relogin LaunchAgent every 4h and at
# login. Safe to run manually any time.
set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.nvm/versions/node/*/bin:/usr/bin:/bin"
EMAIL="you@example.com"
LOG="$HOME/Library/Logs/claudeusage-relogin.log"
NPX="$(command -v npx || echo /usr/local/bin/npx)"
TIMEOUT=90   # seconds; a working login finishes in ~10-20s

echo "[$(date '+%Y-%m-%d %H:%M:%S')] relogin start" >> "$LOG"
# Run under a HARD TIMEOUT. `auth login` normally completes headlessly (it
# reuses the desktop session), but if the callback stalls it waits forever at
# "Paste code here". A hung job blocks every future scheduled run, so we must
# never let it hang — kill it and let the next run (or the widget's kick) retry.
"$NPX" -y @anthropic-ai/claude-code auth login --claudeai --email "$EMAIL" < /dev/null >> "$LOG" 2>&1 &
LOGIN_PID=$!
( sleep "$TIMEOUT"
  if kill -0 "$LOGIN_PID" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] relogin TIMEOUT after ${TIMEOUT}s — killing" >> "$LOG"
    pkill -f "@anthropic-ai/claude-code auth login" 2>/dev/null
    kill -9 "$LOGIN_PID" 2>/dev/null
  fi ) &
WATCHDOG=$!
wait "$LOGIN_PID" 2>/dev/null
STATUS=$?
kill "$WATCHDOG" 2>/dev/null
echo "[$(date '+%Y-%m-%d %H:%M:%S')] relogin exit=$STATUS" >> "$LOG"
exit $STATUS
