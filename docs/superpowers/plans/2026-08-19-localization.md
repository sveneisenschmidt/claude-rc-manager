# Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize the app into de, fr, es, it, ja, zh-Hans with English as base, per docs/superpowers/specs/2026-08-19-localization-design.md.

**Architecture:** Classic `<lang>.lproj/Localizable.strings` as SwiftPM resources; one `L10n` helper selects `Bundle.main` (installed app) vs `Bundle.module` (dev run); failure reasons stay English internally and are mapped to localized text at render time; `make app` copies the `.lproj` set into `Contents/Resources/`.

**Tech Stack:** Swift 5.9 tools, SwiftPM resources, `String(format:)` + `NSLocalizedString`-style lookup, XCTest.

**Read the spec first** — the mechanism section records probe-verified constraints (no xcstrings, no Bundle.module in the .app). On conflict, the spec wins.

---

## Key naming convention

`<area>.<item>[.<variant>]`, all lowercase, dots as separators. Areas:
`menu`, `status`, `reason`, `settings`, `alert`, `warning`, `a11y`,
`external`. Examples: `menu.addFolder`, `status.running`,
`reason.crashLoop`, `settings.capacity`, `alert.remove.title`,
`a11y.warning`. Format strings use `%@` / `%d` with positional forms
(`%1$@`) whenever a translation reorders arguments.

---

### Task 1: L10n helper + English base catalog + call-site migration

**Files:**
- Create: `Sources/ClaudeRCManager/L10n.swift`
- Create: `Sources/ClaudeRCManager/Resources/en.lproj/Localizable.strings`
- Modify: `Package.swift` (defaultLocalization + resources)
- Modify: `Sources/ClaudeRCManager/StatusMenuController.swift`, `SettingsWindow.swift`, `LoginItem.swift`, `StatusIcon.swift`, `main.swift` (only if it holds user-facing strings)
- Test: `Tests/ClaudeRCManagerTests/L10nTests.swift`

- [ ] **Step 1: Extract the complete string inventory from the source.**

Grep the five files above for every user-facing literal (menu titles,
alert texts, tooltips, status labels, accessibility labels, settings
labels, the settings window title, external-server rows including the
`pid %d` fallback, all four warning rows). The spec's Scope section is
the checklist — every bullet there must map to at least one key. The
status glyphs (`○ ● ◐ ✕`) belong to the key's VALUE
(`status.stopped = "○ stopped"`), so translators see the full label.

- [ ] **Step 2: Write `L10n.swift`**

```swift
import Foundation

/// Localization lookup. The installed .app carries the .lproj set in its
/// main bundle (copied by `make app`) — and the main bundle is also what
/// macOS uses for language negotiation. Bare `swift run`/`swift test`
/// have no localized main bundle; they fall back to the SwiftPM resource
/// bundle. Never call `Bundle.module` when the main bundle carries the
/// strings: in the installed app the module accessor would fatalError.
enum L10n {
    static let bundle: Bundle = {
        if Bundle.main.path(forResource: "Localizable", ofType: "strings",
                            inDirectory: nil, forLocalization: "en") != nil {
            return .main
        }
        return .module
    }()

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }

    /// Failure reasons are English identifiers internally (spec). Map the
    /// five fixed reasons exactly, the parameterized exited-status shape
    /// by prefix, and render anything unrecognized as its raw text.
    static func displayReason(_ reason: String) -> String {
        switch reason {
        case "claude not found": return t("reason.claudeNotFound")
        case "not logged in": return t("reason.notLoggedIn")
        case "folder missing": return t("reason.folderMissing")
        case "crash loop — check log": return t("reason.crashLoop")
        case "launch error": return t("reason.launchError")
        default:
            let prefix = "exited, status "
            if reason.hasPrefix(prefix), let n = Int32(reason.dropFirst(prefix.count)) {
                return t("reason.exited", n)
            }
            return reason
        }
    }
}
```

- [ ] **Step 3: Package.swift** — add `defaultLocalization: "en"` to the
package and `resources: [.process("Resources")]` (or per-lproj `.process`
entries — whatever `swift build` accepts warning-free) to the executable
target. Directory layout: all `.lproj` dirs under
`Sources/ClaudeRCManager/Resources/`.

- [ ] **Step 4: Write the full `en.lproj/Localizable.strings`** — one
entry per inventory item from Step 1, values byte-identical to today's UI
text. `reason.exited` = `"exited, status %d"`.

- [ ] **Step 5: Migrate every call site** to `L10n.t(...)` /
`L10n.displayReason(...)`. The `✕ failed (…)` label becomes
`L10n.t("status.failed", L10n.displayReason(reason))` with
`status.failed = "✕ failed (%@)"`. Internal identifiers (ServerState
reasons, precondition strings in ServerManager/ServerProcess, log
content) stay untouched.

- [ ] **Step 6: Write L10nTests**

```swift
import XCTest
@testable import ClaudeRCManager

final class L10nTests: XCTestCase {
    func testDisplayReasonMapsAllShapes() {
        XCTAssertEqual(L10n.displayReason("claude not found"), L10n.t("reason.claudeNotFound"))
        XCTAssertEqual(L10n.displayReason("not logged in"), L10n.t("reason.notLoggedIn"))
        XCTAssertEqual(L10n.displayReason("folder missing"), L10n.t("reason.folderMissing"))
        XCTAssertEqual(L10n.displayReason("crash loop — check log"), L10n.t("reason.crashLoop"))
        XCTAssertEqual(L10n.displayReason("launch error"), L10n.t("reason.launchError"))
        XCTAssertEqual(L10n.displayReason("exited, status 3"), L10n.t("reason.exited", Int32(3)))
        XCTAssertEqual(L10n.displayReason("something new"), "something new")
    }

    func testEnglishLookupReturnsBaseValues() {
        XCTAssertEqual(L10n.t("menu.quit"), "Quit Claude RC Manager")
        XCTAssertFalse(L10n.t("status.running").isEmpty)
    }
}
```

(Adjust the asserted key names to the final inventory; the point is a
lookup that must NOT return the raw key.)

- [ ] **Step 7:** `swift build` (warning-free) + `swift test` all green;
existing tests must pass unchanged (internal identifiers untouched).

- [ ] **Step 8: Commit** — `git commit -m "Extract UI strings into an English base catalog"`

---

### Task 2: Key-parity test

**Files:**
- Create: `Tests/ClaudeRCManagerTests/LocalizationParityTests.swift`

- [ ] **Step 1: Write the parity test.** Load every `*.lproj/Localizable.strings`
from the L10n bundle (`L10n.bundle.paths(forResourcesOfType: "strings" ...)`
or enumerate `Bundle` localizations), parse each with
`PropertyListSerialization` (strings files are plists), and assert every
locale's key set is EXACTLY the `en` set (missing and extra keys both
fail, message names the locale and the differing keys). With only `en`
present the test passes trivially.

- [ ] **Step 2:** Run it; commit — `git commit -m "Add localization key-parity test"`

---

### Task 3: Translations — de, fr, es, it

**Files:**
- Create: `Sources/ClaudeRCManager/Resources/{de,fr,es,it}.lproj/Localizable.strings`

- [ ] **Step 1:** For each language, translate every key from the `en`
catalog. Quality rules from the spec are binding: natural phrasing (no
calques), macOS menu conventions per language (German "Beenden", the
system's ellipsis style), Apple's own localized System-Settings pane
names for the two alerts that reference them, positional specifiers
where word order differs. CLI enum raw values never appear in these
files (they are not localized).
- [ ] **Step 2:** `swift test` — the parity test now checks these locales.
- [ ] **Step 3: Commit** — `git commit -m "Add German, French, Spanish, Italian translations"`

---

### Task 4: Translations — ja, zh-Hans

**Files:**
- Create: `Sources/ClaudeRCManager/Resources/{ja,zh-Hans}.lproj/Localizable.strings`

- [ ] **Step 1:** Translate every key. CJK rules binding: no ASCII spaces
around interpolations mid-sentence, CJK punctuation (、。), Apple's own
localized pane names. Keep the status glyphs (`○ ● ◐ ✕`) exactly as in en.
- [ ] **Step 2:** `swift test` green (parity).
- [ ] **Step 3: Commit** — `git commit -m "Add Japanese and Simplified Chinese translations"`

---

### Task 5: InfoPlist.strings (all seven locales)

**Files:**
- Create: `Resources/InfoPlist/{en,de,fr,es,it,ja,zh-Hans}.lproj/InfoPlist.strings`

- [ ] **Step 1:** Each file holds one key,
`NSAppleEventsUsageDescription`, translated per the same rules. These
live OUTSIDE the SwiftPM target (top-level `Resources/`, next to
`Info.plist`) because only `make app` consumes them. The base value stays
in `Info.plist` (the strings file overrides, it does not supply).
- [ ] **Step 2: Commit** — `git commit -m "Add localized Apple Events purpose strings"`

---

### Task 6: Makefile — ship the localizations

**Files:**
- Modify: `Makefile` (`app` target)

- [ ] **Step 1:** After copying the binary, copy the localizations:

```makefile
	mkdir -p "$(APP_DIR)/Contents/Resources"
	for lproj in "$(BUILD_DIR)/ClaudeRCManager_ClaudeRCManager.bundle/Contents/Resources/"*.lproj; do \
		cp -R "$$lproj" "$(APP_DIR)/Contents/Resources/"; \
	done
	for lang in en de fr es it ja zh-Hans; do \
		test -f "$(APP_DIR)/Contents/Resources/$$lang.lproj/Localizable.strings" \
			|| { echo "missing $$lang.lproj/Localizable.strings"; exit 1; }; \
		cp "Resources/InfoPlist/$$lang.lproj/InfoPlist.strings" \
			"$(APP_DIR)/Contents/Resources/$$lang.lproj/"; \
	done
```

Caveat: the SwiftPM bundle's inner layout may be flat
(`<bundle>/en.lproj/...`) rather than `Contents/Resources` — check the
actual emitted layout with `find .build/release/ClaudeRCManager_ClaudeRCManager.bundle`
first and adjust the glob; the completeness check stays either way.
Recipe lines are TABs. `codesign` stays the last step.

- [ ] **Step 2:** `make app` succeeds; `codesign --verify --strict` exit 0;
all seven `.lproj` dirs present in `Contents/Resources/` with both files.
- [ ] **Step 3: Commit** — `git commit -m "Ship localizations in the app bundle"`

---

### Task 7: Main-spec amendments + README note

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-claude-rc-manager-design.md`
- Modify: `README.md`

- [ ] **Step 1:** Amend the main spec per the localization spec's
"Main-spec amendments" section (UI-language line; `exited (status N)` →
`exited, status N`).
- [ ] **Step 2:** README: one sentence under Usage — the app follows the
macOS system language; list the seven languages.
- [ ] **Step 3: Commit** — `git commit -m "Record localization in spec and README"`

---

### Task 8: Verification

- [ ] **Step 1:** `swift build` warning-free, `swift test` all green.
- [ ] **Step 2:** `make app`; then run the installed-layout binary once
with a language override and assert a German string end to end:

```bash
".build/release/Claude RC Manager.app/Contents/MacOS/ClaudeRCManager" -AppleLanguages '(de)' &
sleep 3; kill %1
```

is NOT sufficient (menu not inspectable headless) — instead verify the
negotiation layer directly: a temporary Swift probe in the scratchpad
that loads `Bundle(path: ".../Claude RC Manager.app")!` and asserts
`localizedString(forKey:)` returns the German value under
`-AppleLanguages '(de)'`-style lookup
(`Bundle.preferredLocalizations(from:)` with `["de"]` must pick "de").
- [ ] **Step 3:** Hand off to Sven: reinstall, spot-check German +
one CJK language visually (menu + one alert), confirm nothing regressed
in English.
