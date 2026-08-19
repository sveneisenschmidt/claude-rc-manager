# Localization — Design

**Date:** 2026-08-19
**Status:** Draft (revised after two-reviewer spec check, same day)
**Extends:** 2026-08-19-claude-rc-manager-design.md

## Purpose

The app's user-facing strings are hardcoded English. Add localization for
six languages — German, French, Spanish, Italian, Japanese, Simplified
Chinese — with English as the base. The app follows the macOS system
language (standard `Bundle` lookup, no in-app language switch). All literal
English UI strings quoted in the main spec are from now on the `en` base
values, not fixed text.

## Scope

Localized (everything a user reads or hears in the UI):

- Menu items: Add Folder…, Start All, Stop All, Start at Login,
  Quit Claude RC Manager, Open login in Terminal…, Open Log, Start, Stop,
  Settings…, Remove…
- The four warning rows: claude CLI not found, Claude not logged in,
  config.json was corrupt (moved to .bak), config.json could not be read
  or preserved
- Section header "External servers" and the row body
  `"<name> — running (external)"` including the `"pid <N>"` fallback
- All seven status labels: `○ stopped`, `◐ starting`, `● running`,
  `◐ stopping`, `◐ restarting…`, `○ ended`, `✕ failed (<reason>)` —
  including the failure reasons (mapping below)
- Settings form: field labels, the "CLI default" picker option, the
  apply-on-next-start hint, Save/Cancel; the settings window title
  `"<name> — Settings"`
- All alert texts (remove confirmation, duplicate folder, save failure,
  login-item errors, Terminal-automation failure)
- Login-item hint ("Install to /Applications first"), tooltip texts
- Status-icon accessibility labels ("Claude RC Manager — warning/active/
  idle"; the app name stays fixed, the state word is translated)
- `NSAppleEventsUsageDescription` via localized `InfoPlist.strings` (see
  Mechanism; the base value stays in `Info.plist` — the `.strings` file
  overrides, it does not supply)

Not localized:

- Log file contents (CLI output) — stays English
- README, spec/plan docs, code comments — English (repo language)
- CLI enum raw values in pickers (`same-dir`, `worktree`, `session`,
  `acceptEdits`, …) — CLI vocabulary the user needs verbatim; only the
  "CLI default" option is prose and is localized
- Internal state/reason identifiers (see mapping below)
- System-supplied text: `error.localizedDescription` in alerts is however
  the system localizes it; mixed-language alert bodies are accepted
- The app name "Claude RC Manager" (product name, not prose)

## Mechanism

Verified against this machine's toolchain (2026-08-19, probes):
`.xcstrings` String Catalogs are copied verbatim by SwiftPM and never
become lookupable; `Bundle.module` does not resolve from any codesignable
location inside a hand-assembled .app (Contents/Resources crashes the
lookup, bundle-at-app-root breaks codesign). Therefore:

- **Classic `<lang>.lproj/Localizable.strings`** for `en`, `de`, `fr`,
  `es`, `it`, `ja`, `zh-Hans`, declared as SwiftPM resources
  (`defaultLocalization: "en"`).
- **Lookup through one helper** (`L10n`): it uses `Bundle.main` when the
  main bundle carries the localizations (the installed .app), otherwise
  `Bundle.module` (bare `swift run`/`swift test`). Code never calls
  `Bundle.module` directly — in the installed app that accessor would
  fatalError.
- **`make app` copies the `<lang>.lproj` directories into
  `Contents/Resources/`** (out of the SwiftPM-emitted
  `ClaudeRCManager_ClaudeRCManager.bundle`, whose name pattern is
  verified). The main bundle's `.lproj` set is what macOS uses for
  language negotiation — without it the app stays English regardless of
  system language (verified). `make app` fails when the copied set is
  incomplete (checks all seven `.lproj` dirs contain
  `Localizable.strings`).
- **`InfoPlist.strings`** per language are hand-maintained in the repo
  (`Resources/InfoPlist/<lang>.lproj/InfoPlist.strings`, lowercase
  `zh-hans`) and copied by `make app`
  into the same `Contents/Resources/<lang>.lproj/` directories. Verified:
  macOS reads the localized info dictionary from there; TCC purpose
  strings come from it. (Manual TCC verification is unreliable with
  ad-hoc signing — the code identity changes per rebuild; accepted.)
- **Failure reasons: internal identifiers stay English.**
  `ServerState.failed(String)` keeps its English reason strings; display
  mapping happens at render time in the menu:
  - exact matches for the five fixed reasons ("claude not found",
    "not logged in", "folder missing", "crash loop — check log",
    "launch error")
  - prefix match for `"exited, status <N>"` → localized format string
    with the number re-attached
  - any unrecognized reason renders as its raw English text (reachable:
    the preflight closure is pluggable)
  Tests keep asserting the English identifiers; the display mapping gets
  its own unit test covering all six shapes plus the fallback.
- Dev-run caveat: language negotiation follows the main bundle, so a bare
  `swift run` may stay English even with `-AppleLanguages` when the
  process's main "bundle" has no localizations; the manual language test
  therefore runs against the installed .app (verified working there).

## Main-spec amendments (same commit)

- "UI language: English." → "UI language: localized (see
  2026-08-19-localization-design.md); English is the base."
- The crash-handling label wording is reconciled to the implemented form
  `exited, status N` (the main spec still shows `exited (status N)` in
  one place).

## Translation quality rules

- Translations are written per language by a reviewer-grade pass, not
  word-by-word from English; each language reads natural, not calqued.
- Japanese and Simplified Chinese: no ASCII spaces inserted around
  interpolations mid-sentence; CJK punctuation (、。) instead of ASCII
  commas/periods.
- Menu items keep macOS conventions per language (German macOS says
  "Beenden", ellipsis "…", etc.).
- References to macOS System Settings panes use Apple's own localized
  pane names per language (Privacy & Security → Automation; General →
  Login Items), not free translations.
- Placeholders: every localized string with interpolation uses positional
  format specifiers where word order differs.

## Testing

- Unit test: `en` is the reference key set; every other locale must have
  exactly the same keys (missing AND extra keys fail).
- Unit test: the failed-reason display mapping covers the five fixed
  reasons, the parameterized exited-status shape, and the raw fallback.
- Manual: install via `make app`, then spot-check German and one CJK
  language by launching the installed binary with `-AppleLanguages`.

## Out of scope

- In-app language switcher
- Localized README or docs
- Localizing CLI output in logs
- String Catalogs / xcstrings (revisit if the project ever moves to an
  Xcode-driven build)
