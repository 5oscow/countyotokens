# count yo tokens

A tiny macOS menu bar app that shows how much of each AI plan you have left, and what your usage
costs, read straight from local logs.

Hard fork of [CodexBar](https://github.com/steipete/CodexBar) v0.84.0, cut down and redesigned.
No upstream remote, no auto-updates.

## Providers

One tally icon; a switcher of provider logos at the top of the menu picks the provider. The logos
are CodexBar's vector marks, embedded as SVG in `LogoData.swift`.

| Provider | Spend | Limits |
|---|---|---|
| Claude | Claude Code and pi/omp logs, at API list prices | Session, Weekly, model-scoped weekly (Fable), via Claude Code's sign-in |
| Codex | `~/.codex/sessions`, at OpenAI list prices | Session and Weekly from ChatGPT, via `~/.codex/auth.json` |
| OpenCode Go | OpenCode's own history (`opencode.db`), as recorded | 5-hour, Weekly, Monthly, via the Go key OpenCode holds |
| OpenCode Zen | OpenCode's own history, as recorded | None: pay as you go |
| Devin | — | Daily and Weekly, with a session token pasted in Settings |
| Droid (Factory) | — | 5-hour, Weekly, Monthly (or Standard/Premium), with an API key |

Each provider's menu shows its limits (percentage left, reset, and pace: reserve or deficit against
an even spread, and whether it lasts until reset), then today and this window, the last 30 days as
daily bars, the last four weekly windows, and the top model. When a provider records no cost (Go
on free models, say), figures are shown in tokens instead.

Credentials are only read, never refreshed or written back: Claude Code's Keychain item through
`/usr/bin/security` (which that item already trusts, so there is no prompt), Codex's `auth.json`,
OpenCode's `credential` table (read-only SQLite). Keys pasted into Settings are stored in the login
Keychain the same way. Each token goes only to its own provider. Limits refresh every 3 minutes by
default and when the menu opens (at most once a minute), and back off when a server asks. Weekly
spend windows follow each provider's reported weekly reset (Monday 00:00 otherwise), or a weekday
picked in Settings.

Prices come from the models.dev `anthropic` and `openai` catalogs: a snapshot is bundled and
refreshed at most once a day.

## Settings

Menu → **Settings…** (⌘,) opens a sidebar window, brought to the front on whichever Space you're on:

- **General**: open at login; how often plan limits are checked (2–15 minutes, or only on request)
  and whether opening the menu checks too; refresh everything now; which day weekly windows start
  (each plan's weekly reset, or a fixed weekday).
- **Menu Bar**: a live preview; the icon (tally marks, a meter that fills with the first two
  limits left, or the provider's logo); what sits next to it (nothing, today's spend, this window's spend, or the lowest
  limit left) and which provider it follows; turning it red under 10% left.
- **Menu**: show or hide each section (limits, pace, today and this window, last 30 days, weekly
  windows, top model); limits as percent left or used; resets as time remaining or date and time;
  hide the email address for screen sharing.
- **Notifications**: when a limit runs low (50, 25, 20, 10 or 5% left), when a low limit resets,
  and when a day's spend passes an amount. Each fires once per window or day. A test button.
- **Providers**, one pane each, dragged to set the switcher order: show it in the menu or not, its
  limits and spend right now, plan and account, where figures come from, the Devin token or Factory
  API key, a link to the provider's usage page, and refresh now.
- **Advanced**: update model prices now, show the data folder, remove saved keys, reset settings.
- **About**.

## Build

```bash
./Scripts/build_app.sh            # builds dist/count yo tokens.app
./Scripts/build_app.sh --install  # replaces /Applications/count yo tokens.app and relaunches
swift run -c release tokbench 5   # times a cold scan and five warm refreshes
swift run -c release tokbench limits claude codex opencode-go devin droid  # fetches limits once
swift run -c release tokbench spend claude codex opencode-go zen         # one spend scan each
.build/release/CountYoTokens -snapshot <folder>   # draws every menu and Settings pane to PNGs, at 2x
"dist/count yo tokens.app/Contents/MacOS/CountYoTokens" -menuProbe <folder>  # opens the real menu per provider
```

`-menuProbe` opens the real menu for each enabled provider, both on it and switching to it while
open, and writes `menu-probe.txt`: every section's height against what its content wants, overlaps,
and whether the main actor kept running. It briefly pops the menu open, so leave the keyboard alone
while it runs. Add `-enabledProviders '(claude,codex,"opencode-go",zen,devin,droid)'` to any of these
to cover every provider for that run without changing the saved selection.

```bash
"/Applications/count yo tokens.app/Contents/MacOS/CountYoTokens" -openSettings menu-bar  # opens a pane
```

Requires macOS 15 and Swift 6.

## How refresh stays instant

- The last result is saved and shown the moment the app starts.
- Every transcript remembers how far it has been read; a refresh stats each file once (`fts`) and
  parses only appended bytes. Files untouched since the oldest day shown are never opened.
- Cold scans map files and parse them in parallel, biggest first; lines are prefiltered with
  `memmem` before any JSON is decoded.
- Cross-file de-duplication is maintained incrementally; unchanged data reuses the last result.
- FSEvents triggers a refresh within a second of a log or OpenCode's database changing.
- Codex sessions are read incrementally the same way; OpenCode's database is re-read only when it
  or its WAL changes.

## License

MIT. See [LICENSE](LICENSE).
