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
- **Design:** pixel-art crab template icon + monospaced-digit percentages;
  green ≥40%, amber 15–39%, red <15%. Adapts to light/dark automatically.
  Stale/error dims the whole item — color is never the only signal.
- **Colorblind (적녹색약):** safety comes from redundancy, not hue choice — every
  level carries a distinct SHAPE in the dropdown (checkmark-circle / caution-circle
  / warning-triangle) and the number is always shown, so the critical state never
  depends on perceiving red.
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

## Launch at login

Toggle **Launch at Login** in the menu. It uses `SMAppService`, falling back to a
LaunchAgent at `~/Library/LaunchAgents/com.seongjun.claudeusage.plist`.
