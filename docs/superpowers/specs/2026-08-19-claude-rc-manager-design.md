# Claude RC Manager — Design

**Date:** 2026-08-19
**Status:** Approved

## Purpose

A macOS menu-bar app (Swift, SwiftPM, macOS 13+) that starts and stops one
`claude remote-control` server per configured folder. Primary use case: keep
servers in standby (`--no-create-session-in-dir`) so new sessions can be
started from the Claude mobile app. The spawn mode is a server-side setting
and cannot be chosen from the phone, so it is configured per folder here.

MVP scope is local-first: build and install via `make`, no code signing or
notarization (documented as a later step, following the hypo-src pipeline).

## Verified CLI surface (claude v2.1.227)

`claude remote-control` flags used by this app:

- `--name <name>` — session name shown in claude.ai/code
- `--spawn <mode>` — `same-dir` | `worktree` | `session` (default: same-dir)
- `--capacity <N>` — max concurrent sessions (default: 32)
- `--permission-mode <mode>` — `acceptEdits`, `auto`, `bypassPermissions`,
  `default`, `dontAsk`, `plan`
- `--[no-]create-session-in-dir` — pre-create a session on start (default: on;
  this app defaults it to **off** for standby operation)

There is **no** `--sandbox` flag in v2.1.227. It is intentionally not part of
the UI; the per-folder extra-args field covers future flags.

Auth check: `claude auth status` prints JSON with a `loggedIn` boolean.

Preconditions (documented in README, not enforced by the app):

- Logged in with a subscription (`claude auth login`)
- Workspace trust accepted once per folder (run `claude` there once)
- Worktree spawn mode requires the folder to be a git repository

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
  `~/Library/Application Support/Claude RC Manager/`. Codable structs.
- **ClaudeCLI** — locates the `claude` binary once at startup via
  `/bin/zsh -lc "command -v claude"` (GUI apps do not inherit shell PATH),
  caches the path; checks login state by running `claude auth status` and
  parsing `loggedIn`.
- **ServerProcess** — one child process per folder, state machine:
  `stopped → starting → running → (restarting | failed)`.
- **ServerManager** — owns all ServerProcess instances, runs autostart on
  launch, stops everything on quit.
- **StatusMenuController** — builds the NSMenu fresh on every open
  (`menuNeedsUpdate`), aggregates the status icon.
- **SettingsWindow** — SwiftUI form per folder.

### Per-folder configuration

| Field | Type | Default |
|---|---|---|
| `id` | UUID | generated |
| `path` | String | chosen via open panel |
| `name` | String | folder basename |
| `spawnMode` | enum: sameDir, worktree, session | sameDir |
| `createSessionInDir` | Bool | **false** (standby) |
| `capacity` | Int | 32 (CLI default) |
| `permissionMode` | enum?, nil = CLI default | nil |
| `extraArgs` | String, shell-like tokenization | "" |
| `autostart` | Bool | false |
| `autoRestart` | Bool | true |

Backoff parameters are fixed policy, not configurable (YAGNI).

### Menu structure

```
[icon: aggregated status]
⚠️ Claude not logged in → "Open login in Terminal…"   (only when needed)
─────
📁 project-a        ● running   ▸  Start / Stop
📁 project-b        ○ stopped   ▸  Open Log
                                   Settings…
                                   Remove…
─────
Add Folder…                        (NSOpenPanel, directories only)
Start All / Stop All
─────
Start at Login                     (checkbox, SMAppService.mainApp)
Quit Claude RC Manager
```

Icon aggregation (SF Symbol template image): all stopped = neutral, ≥1
running = filled/active, ≥1 failed/restarting or not logged in = warning
badge.

Add-folder flow: pick directory → entry created with defaults → settings
window opens immediately so the name can be adjusted.

## Process lifecycle

**Command:** `script -q /dev/null <claude> remote-control --name <name>
--spawn <mode> --capacity <N> [--no-]create-session-in-dir
[--permission-mode <m>] <extraArgs…>` — `script` provides the pseudo-TTY the
CLI expects. Working directory = the folder. Child runs in its own process
group so the whole tree can be signaled. stdout+stderr append to
`~/Library/Logs/ClaudeRCManager/<name>.log`; rotated to `.old` at start when
larger than 5 MB.

**Start:** preconditions checked first (binary found, logged in, folder
exists); failures surface in the menu instead of a cryptic crash.

**Stop (user-initiated):** SIGTERM to the process group, SIGKILL after a 5 s
grace period. No auto-restart, because the user asked for the stop.

**Crash (unexpected exit):** with `autoRestart` on, restart with backoff
1 s, 2 s, 4 s, … capped at 60 s; backoff resets after the process has run
stably for 5 minutes. Menu shows `restarting (retry in Ns)`. With
`autoRestart` off, status becomes `failed (exit N)`; manual start remains
possible.

**Crash-loop guard:** three consecutive exits within 5 s of start → status
`failed`, auto-restart pauses, menu hints "check log". This catches
misconfiguration such as missing workspace trust.

**App quit:** `applicationShouldTerminate` stops all servers (parallel
SIGTERM, shared 5 s deadline) before the app terminates.

**Single instance:** a second app instance exits immediately
(`NSRunningApplication` check).

**Login check:** on app start and before every server start. When not logged
in, the menu shows a warning row with "Open login in Terminal…", which opens
Terminal.app running `claude auth login` (interactive browser OAuth cannot be
done headless). Server starts are blocked until logged in.

## Error handling

- "Open Log" opens the log file with the default app (`NSWorkspace.open`).
- Removing a folder: confirmation alert → stop server → delete config entry
  (log file is kept).
- Missing binary: warning row in the menu with a hint to install Claude Code.

## Testing

`swift test` (XCTest) unit tests for:

- Config round-trip (Codable encode/decode)
- Command-line builder (flags derived from FolderConfig)
- Extra-args tokenizer (quotes, escapes)
- Backoff calculator (sequence, cap, reset)
- `auth status` JSON parser

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
    path).
- README: setup, prerequisites (login, workspace trust per folder, worktree
  mode needs git), Gatekeeper note for downloaded builds, pointer to the
  future signing/notarization step.
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
- Code signing with Developer ID / notarization
- Configurable backoff parameters
- Active workspace-trust detection (failure is visible in the log)
- Log rotation beyond the single `.old` file
