# Claude RC Manager — Design

**Date:** 2026-08-19
**Status:** Approved (revised after two-reviewer spec check, same day)

## Purpose

A macOS menu-bar app (Swift, SwiftPM, macOS 13+) that starts and stops one
`claude remote-control` server per configured folder. Primary use case: keep
servers in standby (`--no-create-session-in-dir`) so new sessions can be
started from the Claude mobile app. The spawn mode is a server-side setting
and cannot be chosen from the phone, so it is configured per folder here.
(The CLI can toggle same-dir/worktree at runtime via the 'w' key, but the app
forwards no stdin, so config.json stays the single source of the spawn mode.)

MVP scope is local-first: build and install via `make`, ad-hoc signature
only — no Developer ID signing, no notarization (documented as a later step,
following the hypo-src pipeline).

## Verified CLI surface (claude v2.1.227)

`claude remote-control` flags used by this app:

- `--name <name>` — session name shown in claude.ai/code
- `--spawn <mode>` — `same-dir` | `worktree` | `session` (default: same-dir)
- `--capacity <N>` — max concurrent sessions in worktree or same-dir mode
  (default: 32; not applicable in session mode)
- `--permission-mode <mode>` — `acceptEdits`, `auto`, `bypassPermissions`,
  `default`, `dontAsk`, `plan`
- `--[no-]create-session-in-dir` — pre-create a session on start (default: on;
  this app defaults it to **off** for standby operation)

There is **no** `--sandbox` flag in v2.1.227. It is intentionally not part of
the UI; the per-folder extra-args field covers future flags (extra args are
appended after the managed flags, duplicates are left to the CLI to resolve).

Auth check: `claude auth status` prints JSON (exit 0) with a `loggedIn`
boolean.

Preconditions (documented in README, not enforced by the app):

- Logged in with a subscription (`claude auth login`)
- Workspace trust accepted once per folder (run `claude` there once)
- Worktree spawn mode requires a git repository or WorktreeCreate/
  WorktreeRemove hooks

## Architecture

SwiftPM executable, runs as accessory app (`LSUIElement = true`, no Dock
icon). App name **Claude RC Manager**, bundle ID
`com.sveneisenschmidt.claude-rc-manager`. UI language: English.

Hybrid UI: AppKit `NSStatusItem`/`NSMenu` for the menu bar (reliable dynamic
submenus and per-item state), SwiftUI forms hosted in `NSWindow` via
`NSHostingView` for settings.

### Components

One file per component, single responsibility:

- **ConfigStore** — loads/saves `config.json` in
  `~/Library/Application Support/Claude RC Manager/`. Codable structs with a
  top-level `version` field. Every mutation writes atomically
  (write-to-temp, then rename). Missing file → start with an empty config.
  Corrupt/unparseable file → rename it to `config.json.bak`, start empty,
  show a warning row in the menu. Duplicate folder paths are rejected with an
  alert when adding.
- **ClaudeCLI** — locates the `claude` binary via
  `/bin/zsh -lc "command -v claude"`; caches the path, re-resolves on each
  start attempt while unresolved. Checks login by running
  `claude auth status` off the main thread with a 5 s timeout; nonzero exit,
  invalid JSON, missing `loggedIn`, or timeout all count as not logged in.
  The result is cached for 60 s and refreshed on menu open and before each
  server start.
- **ServerProcess** — one child process tree per folder; state machine below.
- **ServerManager** — owns all ServerProcess instances, runs autostart on
  launch, stops everything on quit.
- **StatusMenuController** — builds the NSMenu fresh on every open
  (`menuNeedsUpdate`, whole tree from the root). The status-item icon updates
  on every ServerProcess state change, independent of menu open.
- **SettingsWindow** — SwiftUI form per folder; one window per folder at a
  time; explicit Save/Cancel. Saved changes take effect on the next start; a
  running server keeps the arguments it was launched with (no restart, no
  indicator).

### Per-folder configuration

| Field | Type | Default |
|---|---|---|
| `id` | UUID | generated |
| `path` | String | chosen via open panel |
| `name` | String | folder basename |
| `spawnMode` | enum: sameDir, worktree, session | sameDir |
| `createSessionInDir` | Bool | **false** (standby) |
| `capacity` | Int | 32 (CLI default; field disabled for session mode) |
| `permissionMode` | enum?, nil = CLI default | nil |
| `extraArgs` | String | "" |
| `autostart` | Bool | false |
| `autoRestart` | Bool | true (hidden and ignored for session mode) |

extraArgs tokenization: POSIX-like — split on whitespace; single quotes,
double quotes, and backslash escapes supported; no tilde, glob, or variable
expansion. The tokens are passed as argv entries (no shell involved).

Backoff parameters are fixed policy, not configurable (YAGNI).

### Menu structure

```
[icon: aggregated status]
⚠️ Claude not logged in → "Open login in Terminal…"   (only when needed)
─────
📁 project-a   ● running    ▸ ┐
📁 project-b   ○ stopped    ▸ ├─ each folder has the same submenu:
                              │    Start | Stop   (one item, toggles)
                              │    Open Log
                              │    Settings…
                              │    Remove…
─────
Add Folder…                        (NSOpenPanel, directories only)
Start All / Stop All
─────
Start at Login                     (checkbox, SMAppService.mainApp)
Quit Claude RC Manager
```

Status icon: three SF Symbols, one per bucket, template rendering (a template
image is one color, so buckets differ by symbol shape, not color):

1. **Warning** (highest precedence): any folder `failed`, or not logged in,
   or `claude` binary missing, or config was corrupt →
   `exclamationmark.triangle`.
2. **Active**: any folder `starting`, `running`, `stopping`, or `restarting`
   → filled symbol variant.
3. **Neutral**: everything stopped → outline symbol variant.

Per-folder status labels: `stopped`, `starting`, `running`, `stopping`,
`restarting…` (static text, no countdown), `failed (<reason>)`, `ended`
(session mode only, see lifecycle).

Add-folder flow: pick directory → duplicate-path check → entry created with
defaults → settings window opens immediately so the name can be adjusted.

Start All: starts every folder that is not already running/starting; it also
clears a crash-loop pause. Stop All: user-initiated stop for every folder,
cancels pending restart timers. Both have exactly the per-folder semantics.

Start at Login: `SMAppService.mainApp.register()/unregister()`. A thrown
error shows an alert. When the app bundle is not in `/Applications`, the
checkbox is disabled with a hint ("Install to /Applications first").

## Process lifecycle

### Command and process tree

`script -q /dev/null <claude> remote-control --name <name> --spawn <mode>
[--capacity <N>] [--no-]create-session-in-dir [--permission-mode <m>]
<extraArgs…>` — `script` provides the pseudo-TTY the CLI expects. Working
directory = the folder. stdin is explicitly `/dev/null` (script fails on
socket stdin and must not inherit the app's).

**Signal reality (verified 2026-08-19 on this machine):** `script` puts the
inner command into its **own session and process group** (`login_tty`).
Signaling script's process group never reaches `claude` directly; it only
dies as a side effect of the pty closing (SIGHUP), and a HUP/TERM-trapping
child survives and is orphaned. Therefore:

- After spawn, ServerProcess resolves the **inner child pid** via
  `pgrep -P <script-pid>` (retried briefly until it appears).
- All stop/kill signals target the **inner child's process group** (the
  inner pid is its own group leader), and `script` is terminated afterwards.
- `script`'s termination (Process terminationHandler) is the exit event; the
  reported value is shown as `exited (status N)` — `script` collapses a
  signal death into the raw signal number, so 9 can mean "exit 9" or
  "SIGKILL"; the label does not claim to distinguish them.

Log: stdout+stderr of `script` append to
`~/Library/Logs/ClaudeRCManager/<id>.log` (the immutable UUID, so renames
and duplicate names cannot mix logs; the menu's Open Log knows the mapping).
The writer strips ANSI escape sequences and CR overwrites before appending
(the pty stream is otherwise control-code soup). Rotated to `.old` at start
when larger than 5 MB.

### States

`stopped → starting → running → stopping → stopped`, plus `restarting` and
`failed`. Transitions:

- **starting → running:** the process is still alive **5 s** after spawn.
- **starting/running → exit:** see crash handling below.
- **Manual Start** is allowed from `stopped`, `failed`, and `ended`; it
  resets the crash-loop counter and clears a crash-loop pause.
- **Stop (user, incl. Stop All, incl. during restarting):** cancels any
  pending restart timer, sends SIGTERM to the inner process group, SIGKILL
  after 5 s, state `stopping → stopped`. No auto-restart — the user asked.

### Start preconditions

Checked before every start: binary found, logged in, folder exists. A
failure sets the folder to `failed (<reason>)` with exactly these reasons:
`claude not found`, `not logged in`, `folder missing`. Precondition failures
never count toward crash-loop or backoff accounting. (Folder existence is
checked at start only; a folder vanishing mid-run is not detected.)

### Crash handling

Any exit not preceded by a user Stop is unexpected, **regardless of exit
code** — except in session spawn mode: there the CLI exits by design when
the session ends (help text: "exits when that session ends"), so an exit is
the expected end of the session. Session-mode folders go to state `ended`
(manual start begins the next session); autoRestart does not apply.

For same-dir/worktree folders with `autoRestart` on:

1. On exit, first the crash-loop check: **3 consecutive exits, each within
   5 s of entering `starting`** → state `failed (crash loop — check log)`,
   auto-restart pauses. Only a manual Start (or Start All) clears the pause.
   This is intentionally reachable before the backoff cap: fast crashes mean
   misconfiguration (e.g. missing workspace trust), and waiting 60 s between
   doomed attempts helps nobody.
2. Otherwise schedule a restart with backoff 1 s, 2 s, 4 s, … capped at
   60 s; state `restarting…`.
3. A run of ≥ 5 minutes resets both the backoff step and the crash-loop
   counter.

With `autoRestart` off: state `failed (exited, status N)`; manual start
remains possible.

### Login check

On app start, on menu open (60 s cache), and before every server start. When
not logged in, the menu shows the warning row with "Open login in
Terminal…", which opens Terminal.app running `claude auth login`
(interactive browser OAuth cannot be done headless). Server starts are
blocked while logged out. Autostart folders skipped at launch because of a
failed login check stay stopped; they are not auto-started when login later
succeeds (the user starts them manually).

### Autostart and quit

Autostart: on launch, all `autostart` folders start in parallel (no
ordering guarantees).

Quit: `applicationShouldTerminate` returns `.terminateLater`, cancels all
pending restart timers, stops all servers in parallel (SIGTERM to inner
process groups, shared 5 s deadline, then SIGKILL for stragglers), then
calls `NSApp.reply(toApplicationShouldTerminate: true)`. Force-quit (SIGKILL
of the app) runs no cleanup and leaves servers running — accepted MVP
limitation, noted in the README.

Single instance: a second app instance exits immediately
(`NSRunningApplication` check).

## Error handling

- "Open Log" opens the log file with the default app (`NSWorkspace.open`).
- Removing a folder: confirmation alert → stop server → delete config entry
  (log file is kept).
- Missing binary: warning row in the menu with a hint to install Claude
  Code; the path is re-resolved on the next start attempt (no app restart
  needed).

## Testing

`swift test` (XCTest) unit tests for:

- Config round-trip (Codable encode/decode), corrupt-file recovery
- Command-line builder (flags derived from FolderConfig, session-mode
  omissions)
- Extra-args tokenizer (quotes, escapes, no expansion)
- Backoff calculator (sequence, cap, reset) and crash-loop counter rules
- `auth status` JSON parser (valid, invalid, missing field)
- ANSI/CR log-stream filter

The process launcher sits behind a protocol so ServerManager logic is
testable with a fake. UI is tested manually.

## Repository & build

- `Package.swift` — executable target, platform macOS 13; sources under
  `Sources/ClaudeRCManager/`.
- `Makefile`:
  - `make app` — `swift build -c release`, assemble
    `Claude RC Manager.app` (Info.plist with `LSUIElement`, binary into
    `Contents/MacOS/`), ad-hoc `codesign -s -` (required for SMAppService
    login items to work reliably).
  - `make install` — copy to `/Applications` (login item needs a stable
    path). README caveat: an ad-hoc identity changes on every rebuild, so a
    reinstall may flip the login item to "requires approval" in System
    Settings.
- README: setup, prerequisites (login, workspace trust per folder, worktree
  mode needs git or worktree hooks), Gatekeeper note for downloaded builds,
  force-quit limitation, pointer to the future signing/notarization step.
- MIT LICENSE, `.gitignore` (`.build/`, `*.app`, `.DS_Store`).
- CI (`.github/workflows/build.yml`): `swift build` + `swift test` on
  `macos-14` for push/PR.
- Release (`.github/workflows/release.yml`): on tag `v*`, build the .app,
  zip it (ad-hoc signed, not notarized), attach to a GitHub release.
  Notarization following the hypo-src pattern (Developer ID cert +
  notarytool + stapler, same secret names) is a documented later step, not
  MVP.

## Out of scope (MVP)

- `--sandbox` flag (does not exist in v2.1.227)
- Developer ID signing / notarization
- Configurable backoff parameters
- Active workspace-trust detection (failure is visible in the log)
- Log rotation beyond the single `.old` file
- Detecting a folder that vanishes while its server runs
- Cleanup of orphaned servers after a force-quit of the app
- Spawning the CLI on a directly-owned pty (posix_spawn + openpty) instead
  of `script` — would give exact child status and cleaner signaling; the
  pgrep approach is the smaller MVP step
