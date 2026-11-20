# count yo tokens

A tiny macOS menu bar app that shows how much of your Claude plan is left, and what your usage
would cost at API list prices, read straight from local logs.

Hard fork of [CodexBar](https://github.com/steipete/CodexBar) v0.84.0, cut down to the one card it
actually needs. No upstream remote, no auto-updates.

## What it shows

- **Plan limits**: Session (5-hour), Weekly and model-scoped weekly limits such as Fable, each with
  the percentage left and when it resets
- **Today** and **this window** (the current 7-day weekly-limit window): cost and tokens
- **Last 30 days**: total, a daily bar chart (hover a bar for that day), and the daily average
- **Weekly windows**: the current window and the three before it, each with tokens, cost and a meter
- **Top model** by share of spend, and when the figures were last updated

Limits come from Anthropic's usage endpoint, using the sign-in Claude Code already keeps in your
login Keychain (read with `/usr/bin/security`, which that item already trusts, so there is no prompt).
The token is sent only to `api.anthropic.com`, never stored or refreshed here; if it has expired,
limits pause until Claude Code renews it. They refresh every 3 minutes and when you open the menu
(at most once a minute), and back off when the server asks. The weekly windows are counted from the
weekly reset Anthropic reports.

Costs: Claude Code transcripts (`~/.claude/projects`, `~/.config/claude/projects`, or
`$CLAUDE_CONFIG_DIR/projects`) and pi / oh-my-pi sessions (`~/.pi/agent/sessions`,
`~/.omp/agent/sessions`) for Anthropic models. Account email and plan come from `~/.claude.json`.
Prices are the models.dev `anthropic` catalog: a snapshot is bundled, refreshed at most once a day.

## Settings

Menu → **Settings…** (⌘,):

- **Show today's spend in the menu bar** next to the tally icon.
- **Open at login**.

## Build

```bash
./Scripts/build_app.sh            # builds dist/count yo tokens.app
./Scripts/build_app.sh --install  # replaces /Applications/count yo tokens.app and relaunches
swift run -c release tokbench 5   # times a cold scan and five warm refreshes
swift run -c release tokbench limits  # fetches and prints the plan limits once
```

Requires macOS 15 and Swift 6.

## How refresh stays instant

- The last result is saved and shown the moment the app starts.
- Every transcript remembers how far it has been read; a refresh stats each file once (`fts`) and
  parses only appended bytes. Files untouched since the oldest day shown are never opened.
- Cold scans map files and parse them in parallel, biggest first; lines are prefiltered with
  `memmem` before any JSON is decoded.
- Cross-file de-duplication is maintained incrementally; unchanged data reuses the last result.
- FSEvents triggers a refresh within a second of Claude writing a line.

## License

MIT. See [LICENSE](LICENSE).
