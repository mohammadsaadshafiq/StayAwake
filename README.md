# Wigbat 🦇

A tiny bat that lives tucked at the top of your screen. It keeps your Mac
awake while Claude Code is working, and lets it sleep the moment you're done
— no more losing a long-running session because the lid dimmed the screen.

| Awake | Asleep |
|---|---|
| ![Wigbat awake, hanging from its branch](wigbat-awake-final.png) | ![Wigbat asleep, wrapped in its wings with zzz](wigbat-asleep-final.png) |

## What it does

- **Ties keep-awake to Claude Code itself.** A `SessionStart` hook calls
  `stayawake` (runs `caffeinate -dimsu`) and a `SessionEnd` hook calls
  `killawake`, so your Mac only stays awake while a Claude Code session is
  actually open. Multiple concurrent sessions are ref-counted, so closing
  one terminal doesn't let the Mac sleep while another is still busy.
- **Self-heals.** If a session is force-quit and the `SessionEnd` hook never
  fires, Wigbat notices no `claude` process is actually running anymore and
  turns keep-awake off on its own.
- **Hides until you need it.** Tucked at the top of the screen; hover near
  the top edge and it slides fully into view. Move away and it tucks itself
  back in.
- **One click to override.** Left-click the bat any time to manually force
  the Mac awake or let it sleep, regardless of what Claude Code is doing.
- **Pops up for permission prompts.** When Claude Code needs your attention
  (the `Notification` hook), the bat springs out with an excited shake, plays
  a soft chirp (toggleable), and shows the message in a speech bubble for
  15 seconds. Click the bubble to dismiss it early.
- **Sleep-safety timer.** Optional hard cap (2/4/8 hours) on how long
  keep-awake can run, no matter what sessions or hooks are doing — so a
  runaway session can't drain your battery overnight. The menu shows a
  live "auto-sleep in …" countdown, and the bat tells you when it fires.
- **Recent messages.** Both menus keep the last few Claude notifications
  with timestamps, so a missed bubble isn't gone forever.
- **Drag it anywhere — on any display.** Free-hand positioning; the bat
  remembers which screen you dropped it on and stays there across
  monitor plug/unplug (falling back to the main display).
- **Menu bar icon** (🦇 awake / 💤 asleep) as a second, always-reachable
  control surface, independent of the floating bat.
- **Live status in every menu** — how many Claude sessions are running and
  how long the Mac has been kept awake.
- **Battery-friendly option** — "Keep Display On" toggle: turn it off and
  the screen is allowed to sleep while the Mac itself stays awake for
  Claude (`caffeinate -imsu` instead of `-dimsu`).

## Controls

- **Left-click** the bat — toggle keep-awake manually
- **Click** the speech bubble — dismiss it
- **Drag** the bat — move it anywhere, on any display
- **Right-click** the bat — menu: Keep Mac Awake ✓, Keep Display On ✓,
  Sleep-Safety Timer ▸, Chirp on Notifications ✓, Recent Messages ▸,
  Hide, Bigger/Smaller, Rotate Left/Right, Reset Position, Help, Quit
- **Menu bar icon** — same menu, plus Show/Hide Buddy

## Opening & relaunching it

You normally never launch Wigbat by hand — `install.sh` starts it and a
LaunchAgent auto-launches it at every login (and auto-restarts it if it
crashes). While running it shows up **only** as the menu-bar icon (🦇/💤) and
the floating bat — there's deliberately no Dock icon, since it's an accessory
app.

The one time you need to reopen it is after you've chosen **Quit** from its
menu — a deliberate Quit stays quit until you relaunch it. Because it's
installed as `/Applications/Wigbat.app`, you can reopen it however you like:

- **Spotlight** — ⌘-Space, type "Wigbat", hit Enter
- **Finder** — double-click `Wigbat.app` in `/Applications`
- **Dock** — drag `Wigbat.app` into the Dock once for a permanent launcher
- **Terminal** — `open -a Wigbat`

Only one bat ever runs at a time — launching it again while it's already up
just does nothing (a single-instance lock guards against duplicates).

## How it's built

- `bin/stayawake`, `bin/killawake` — the actual caffeinate wrapper scripts,
  usable standalone from the terminal too. Both write current state to
  `state/state.json` so the app can reflect it.
- `bin/hook-session-start.sh`, `bin/hook-session-end.sh` — ref-counting
  wrappers called by Claude Code's hooks (see `~/.claude/settings.json`),
  so keep-awake only turns off once *all* concurrent sessions have ended.
- `bin/hook-notification.sh` — called by the `Notification` hook, stashes
  the message into `state/message.json` for the bat's speech bubble.
- `swift/BuddyApp.swift` — the actual floating bat, a small AppKit app
  (no Xcode project needed, just `swiftc`). Runs as an `.accessory` app
  (no Dock icon), floats above all apps and full-screen Spaces via a
  `.statusBar`-level `NSPanel` with `.fullScreenAuxiliary` collection
  behavior. Also self-heals: its 1s poll loop checks real `claude`
  processes via `pgrep` and forces sleep if a session was force-killed
  without `SessionEnd` ever firing. Holds an exclusive `flock` on
  `state/buddy.lock` at startup so only one instance can ever run,
  regardless of how it was launched.
- `bin/make-app.sh` — compiles the binary and packages it as
  `/Applications/Wigbat.app` (an `.icns` icon generated from the artwork, plus
  an `Info.plist` with `LSUIElement` so it stays menu-bar-only while running).
  This is what makes the bat launchable from Spotlight/Finder/Dock. Assets and
  state are still read from `~/claude-awake-buddy`, so the bundle only carries
  the binary + icon.
- `assets/` — the bat artwork (branch, awake body, asleep body, menu bar
  icons), all as transparent PNGs.
- `~/Library/LaunchAgents/com.wigbat.buddy.plist` — keeps the bat app
  running: points at `/Applications/Wigbat.app/Contents/MacOS/buddy`,
  auto-launches at login, auto-restarts if it ever crashes, but a deliberate
  Quit stays quit (relaunch it from Spotlight/Finder — see above).

## Installing on another Mac

Requires the Xcode Command Line Tools (`xcode-select --install`) for
`swiftc` — no full Xcode install needed.

```
git clone https://github.com/mohammadsaadshafiq/StayAwake.git ~/claude-awake-buddy
cd ~/claude-awake-buddy
./install.sh
```

`install.sh` compiles the app, makes the `bin/` scripts executable, merges
the `SessionStart`/`SessionEnd`/`Notification` hooks into
`~/.claude/settings.json` (backing up the original first, and safe to
re-run — it won't add duplicate entries), writes a LaunchAgent pointed at
wherever you cloned the repo, and starts it. Restart any open Claude Code
sessions afterward so the new hooks take effect.

## Known limitations

- The bat's floating window is a small fixed hit-zone near the top of the
  screen — dragging or right-clicking there will intercept clicks meant for
  whatever's underneath, same as any menu-bar dropdown would.
- Position/scale/tilt are saved per-Mac in `state/prefs.json`, not synced
  anywhere.
- Not yet packaged for Homebrew or as a distributable Claude Code skill —
  today it's a personal, single-machine setup.
