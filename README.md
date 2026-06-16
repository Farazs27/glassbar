# GlassBar

A tiny **Liquid Glass status HUD** that floats at the top‑center of your Mac and shows, at a glance, **what's running** across your AI / dev tools plus **what's playing** — without touching your Dock or menu bar.

![GlassBar](docs/screenshot.png)

From left to right the bar shows:

- **App logos** — VS Code · Cursor · Claude desktop · ChatGPT. Full‑color when the app is running, dimmed when it isn't.
- **`✦ CC`** — running **Claude Code** sessions + **today's spend** (e.g. `$23.78`).
- **`</> cx`** — running **Codex** sessions + **weekly limit used** (e.g. `84%wk`).
- **`♪`** — the current **now‑playing** track (system‑wide), or *Not playing*.
- **⌄** — expands a detail popover with full usage for both tools.

The popover breaks down:

| Claude Code | Codex |
|---|---|
| Today — cost + tokens | 5‑hour window — % used + reset |
| This week — cost + tokens | Weekly window — % used + reset |
| Active 5‑hour block — cost + reset | Session + today tokens |

## Why

It's a single always‑on glance for people who run several coding agents and editors at once: which tools are live, how many sessions, and how close you are to your rate limits — so you're never surprised by a wall.

## How it works (data sources)

Everything is read from **local data on your machine** — no accounts, no network calls of our own.

- **App running state** → `NSWorkspace` (by bundle id). Instant, no permissions.
- **CLI sessions** → `ps`, counting *session‑leader* processes named `claude` / `codex` (a process whose parent isn't itself the same tool), so worker subprocesses don't inflate the number.
- **Claude usage** → [`ccusage`](https://github.com/ryoppippi/ccusage), which aggregates the token/cost data Claude Code writes to `~/.claude/projects/**/*.jsonl`.
- **Codex usage & limits** → parsed from the newest rollout in `~/.codex/sessions/**` (`rate_limits` → 5‑hour `primary` + weekly `secondary`, and `total_token_usage`).
- **Now playing** → [`media-control`](https://github.com/ungive/media-control), a MediaRemote bridge that works system‑wide (Spotify, Apple Music, browsers, …).

> **One honest gap:** Claude Code does **not** store its plan *weekly‑limit %* / reset locally — it fetches that live for `/usage`. So GlassBar shows Claude **usage totals + the active 5‑hour block**, and surfaces a note pointing you to `/usage` for the official weekly number. Codex *does* expose its limits locally, so those are shown in full.

The usage numbers refresh every 60 s; running‑state and now‑playing every 3 s.

## Requirements

- macOS **26 (Tahoe)** or later — uses the real SwiftUI Liquid Glass API.
- Swift toolchain (Xcode **or** Command Line Tools: `xcode-select --install`).
- [`ccusage`](https://github.com/ryoppippi/ccusage): `npm install -g ccusage`
- [`media-control`](https://github.com/ungive/media-control): `brew install media-control`
- `jq` (preinstalled on macOS).

## Build & install

```bash
git clone https://github.com/Farazs27/glassbar.git
cd glassbar
./build.sh
```

`build.sh` compiles a release binary, assembles `GlassBar.app`, installs it to `~/Applications`, registers a **login LaunchAgent** (so it auto‑starts), and launches it. Re‑run it any time to update.

## Usage

- **Drag** the bar anywhere — it remembers nothing fancy, just move it where you like.
- Click the **⌄** chevron for the detailed usage popover.
- **Quit** from the popover's *Quit* button (it won't come back until next login).

## Uninstall

```bash
launchctl bootout "gui/$(id -u)/com.faraz.glassbar"
rm -f ~/Library/LaunchAgents/com.faraz.glassbar.plist
rm -rf ~/Applications/GlassBar.app
```

## Customize

The watched GUI apps live in `GUI_APPS` near the top of `Sources/GlassBar/main.swift` — add/remove `AppDef(id:name:tint:)` entries (find a bundle id with `osascript -e 'id of app "Name"'`). Rebuild with `./build.sh`.

## Project layout

```
Sources/GlassBar/main.swift   # model + Liquid Glass UI + floating panels
Resources/glassbar-usage.sh   # emits Claude + Codex usage as JSON
packaging/Info.plist          # LSUIElement app metadata
build.sh                      # build → bundle → install → autostart
```

## Notes & limitations

- Session counts reflect **active CLI processes**, which for heavy/agentic setups can be higher than the number of terminal windows you have open.
- Codex limits come from your **most recent** Codex session, so they update the next time you run Codex.
- `media-control` relies on a private MediaRemote bridge; Apple has tightened this in past releases, so a future macOS update could affect now‑playing.

## License

MIT © 2026 Faraz Sharifi
