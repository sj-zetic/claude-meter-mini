# ClaudeUsage — macOS menu bar widget

A native menu bar app that shows how much of your Claude (Pro/Max) usage is left.
The menu bar shows **both** frequent blockers — session (5-hour) and weekly — as
`S 79% · W 79%`, each number colored by its own severity. The dropdown breaks out
every limit with a progress bar and a reset countdown. The menu bar glyph is a
pixel-art crab drawn as a template image (recolors for light/dark).

Data comes from the same source as Claude Code's `/usage` command:
`GET https://api.anthropic.com/api/oauth/usage`.

## Requirements

- macOS 13+ (built and tested on 15.6, Apple Silicon)
- Swift toolchain (Command Line Tools is enough — no full Xcode needed)

## Build & install

```bash
./scripts/install.sh
```

This runs `swift build -c release`, assembles `~/Applications/ClaudeUsage.app`
(ad-hoc signed, `LSUIElement` so no Dock icon), and launches it. Re-run it to
update after code changes.

## Connecting it (one-time)

The widget reads your OAuth token from the `Claude Code-credentials` Keychain
item that the Claude Code **CLI** creates on login. If you only use the Claude
desktop app, that item won't exist yet and the widget shows `–` / "Not signed in".

To connect, run once in Terminal (also available via the menu's *Copy Setup
Command*):

```bash
npx -y @anthropic-ai/claude-code
```

(Use `npx`, not a global `npm install -g`, which fails with EACCES when npm's
prefix is `/usr/local`.) Then type `/login` and finish in the browser. The first time the widget reads the
Keychain, macOS asks for access — click **Always Allow** (not just Allow) so it
doesn't re-prompt.

> The desktop app keeps its token in encrypted "Claude Safe Storage", which the
> widget intentionally does not pry into. The CLI login above is the supported,
> stable way to give the widget its own read-only credential.

## Design notes

- **Cost:** the `/api/oauth/usage` endpoint is a status read, not an inference
  call — polling it consumes **0 tokens** and never counts against the 5-hour or
  weekly limits. Only the endpoint's own request rate is bounded (handled by the
  90 s spacing + backoff).
- **Accuracy:** server-side utilization, refreshed every 90 s, on menu-open
  (throttled 10 s), and via *Refresh Now* (⌘R). A local per-minute tick re-renders
  the reset countdown between polls (no network) so it counts down live. Exponential backoff to 15 min on
  429/errors, honoring `Retry-After`. Last result is cached to
  `~/Library/Application Support/ClaudeUsage/last.json` so a relaunch shows data
  instantly (marked stale until the first live fetch).
- **Design:** pixel-art crab icon (always white) + monospaced-digit percentages.
  Two-level, colorblind-simple color: **green** when a limit is healthy (≥40%
  left), **white** otherwise (neutral-to-poor). No red/amber and never gray — even
  stale data keeps its green/white value color.
- **Colorblind (적녹색약):** green vs. white avoids the red/green problem entirely;
  the dropdown rows also carry a distinct SHAPE (checkmark vs. warning-triangle)
  and the number is always shown.
- **Accessibility:** VoiceOver labels on the status item and every row
  ("Weekly limit: 12 percent remaining, resets in 2 hours"). No animation, so
  Reduce Motion is a non-issue.
- **Token refresh:** primary strategy is re-reading the Keychain (Claude Code
  keeps it fresh); fallback is our own refresh via
  `https://platform.claude.com/v1/oauth/token`, kept in memory only so it never
  clobbers Claude Code's stored state.

## Debug helpers

```bash
# Print credential discovery + one live fetch, then exit:
.build/release/ClaudeUsage --dump

# Render any UI state without real creds/network:
CLAUDEUSAGE_FORCE_STATE=ok|notsignedin|stale|error|rate .build/release/ClaudeUsage
# CLAUDEUSAGE_OPEN_MENU=1 auto-opens the dropdown on launch (for screenshots).
```

## Always-on

`install.sh` sets up a LaunchAgent (`~/Library/LaunchAgents/com.seongjun.claudeusage.plist`)
so the widget **starts at login and auto-restarts if it crashes** — but a deliberate
Quit is honored (`KeepAlive → SuccessfulExit:false`, i.e. restart only on abnormal
exit). To stop it permanently:

```bash
launchctl bootout gui/$(id -u)/com.seongjun.claudeusage
rm ~/Library/LaunchAgents/com.seongjun.claudeusage.plist
```

The menu's **Launch at Login** toggle (via `SMAppService`) manages the same thing.

### Staying signed in (auto-relogin)

The access token lasts ~24h. The token *refresh* endpoint hard-rate-limits this
credential (persistent 429), so the widget does **not** refresh — it's a pure
Keychain reader. Instead a second LaunchAgent (`…relogin`) runs `scripts/relogin.sh`
**every 4h and at login**, which calls `claude auth login --claudeai`. That
completes headlessly by reusing the signed-in **Claude desktop** session (no browser,
no rate limit) and writes a fresh token to the Keychain the widget reads.

Requirement: stay signed into the Claude desktop app.

> **Email hint (optional):** `relogin.sh` no longer hardcodes any email — the
> `EMAIL` variable is blank by design (no address is committed to this repo). Login
> works fine without it. If you want the sign-in page pre-filled with your address,
> set `CLAUDEUSAGE_EMAIL="you@example.com"` at the top of `scripts/relogin.sh`.

Logs: `~/Library/Logs/claudeusage-relogin.log`. To stop it:

```bash
launchctl bootout gui/$(id -u)/com.seongjun.claudeusage.relogin
rm ~/Library/LaunchAgents/com.seongjun.claudeusage.relogin.plist
```
