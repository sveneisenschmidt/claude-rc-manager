# Localization — Design

**Date:** 2026-08-19
**Status:** Draft
**Extends:** 2026-08-19-claude-rc-manager-design.md

## Purpose

The app's user-facing strings are hardcoded English. Add localization for
six languages — German, French, Spanish, Italian, Japanese, Simplified
Chinese — with English as the base. The app follows the macOS system
language (standard `Bundle` lookup, no in-app language switch).

## Scope

Localized (everything a user reads in the UI):

- Menu items and section headers (Add Folder…, Start All, Stop All, Start
  at Login, Quit Claude RC Manager, External servers, the warning rows,
  Open login in Terminal…)
- Per-folder submenu (Start, Stop, Open Log, Settings…, Remove…)
- Status labels (`○ stopped`, `● running`, `✕ failed (…)`, …) including
  the failure reasons shown in parentheses
- Settings form (field labels, picker labels, the apply-on-next-start
  hint, Save/Cancel)
- All alert texts (remove confirmation, duplicate folder, save failure,
  login-item errors, Terminal-automation failure)
- Login-item hint ("Install to /Applications first"), tooltip texts
- `NSAppleEventsUsageDescription` in Info.plist (via `InfoPlist.strings`
  per localization inside the app bundle)

Not localized:

- Log file contents (CLI output, plus our own markers) — stays English
- README, spec/plan docs, code comments — English (repo language)
- CLI flag values shown as technical identifiers (`same-dir`, `worktree`,
  `session`, `acceptEdits`, …) — these are CLI vocabulary the user needs
  verbatim for the CLI's own docs; pickers show them unchanged
- Internal state/reason identifiers (see below)

## Mechanism

- `Package.swift`: `defaultLocalization: "en"`; the executable target gets
  localized resources. Implementation picks String Catalogs (`.xcstrings`)
  if the pinned toolchain's SwiftPM builds them, otherwise classic
  `<lang>.lproj/Localizable.strings` — the plan verifies this with a probe
  before committing to one. Locale codes: `en`, `de`, `fr`, `es`, `it`,
  `ja`, `zh-Hans`.
- Code uses `String(localized:bundle:)` / `NSLocalizedString` with
  `Bundle.module`.
- **Internal identifiers stay English.** `ServerState.failed(String)`
  keeps its English reason strings ("claude not found", "not logged in",
  "folder missing", "crash loop — check log", "exited, status N", "launch
  error"); the menu maps known reasons to localized display text at render
  time. Tests keep asserting the English identifiers; display mapping gets
  its own unit test.
- **Makefile change:** SwiftPM emits the localized resources as
  `ClaudeRCManager_ClaudeRCManager.bundle` next to the binary; `make app`
  must copy it into `Contents/Resources/` so `Bundle.module` resolves
  inside the installed .app. Without this the installed app would crash or
  fall back to keys — the plan adds a bundle-presence check to `make app`.
- App name stays "Claude RC Manager" in every language (product name, not
  prose).

## Translation quality rules

- Translations are written per language by a reviewer-grade pass, not
  word-by-word from English; each language reads natural, not calqued.
- Japanese and Simplified Chinese: no ASCII spaces inserted around
  interpolations mid-sentence; CJK punctuation (、。) instead of ASCII
  commas/periods.
- Menu items keep macOS conventions per language (e.g. German macOS menus
  use "Beenden", ellipsis style "…").
- Placeholders: every localized string with interpolation uses positional
  format specifiers where word order differs.

## Testing

- Unit test: every key present in every locale (parse the catalogs/tables,
  compare key sets — a missing key falls back to English silently, which
  this test turns into a failure).
- Unit test: the failed-reason display mapping covers all six known
  reasons.
- Manual: launch with `defaults write ... AppleLanguages` or
  `-AppleLanguages '(de)'` argument to spot-check German and one CJK
  language.

## Out of scope

- In-app language switcher
- Localized README or docs
- Localizing CLI output in logs
