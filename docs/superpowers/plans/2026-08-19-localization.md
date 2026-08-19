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

Note: `main.swift` produces two of the internal reason identifiers in the
preflight closure ("claude not found", "not logged in") — those are
identifiers, NOT UI text; do not touch them. Only genuine user-facing
strings in main.swift (if any) migrate.

SwiftPM lowercases lproj names in the emitted bundle: `zh-Hans.lproj`
becomes `zh-hans.lproj` and `Bundle.localizations` reports `"zh-hans"`
(verified). Use `zh-hans` everywhere downstream (Makefile, parity test,
InfoPlist directory name); negotiation for `zh-Hans` preferences still
resolves to it correctly.

- [ ] **Step 2: Package.swift** — add `defaultLocalization: "en"` to the
package and `resources: [.process("Resources")]` to the executable
target (verified warning-free with multiple .lproj dirs under
`Sources/ClaudeRCManager/Resources/`).

- [ ] **Step 3: Write `L10n.swift`**

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

Two traps this test must avoid (both probe-verified): `L10n.t` falls back
to the key, so comparing two `t()` calls passes even when the catalog is
missing entirely; and negotiated lookups return GERMAN on this machine
under `swift test` (the module bundle negotiates against system
language), so never assert a specific language through `L10n.t`.

```swift
import XCTest
@testable import ClaudeRCManager

final class L10nTests: XCTestCase {
    /// Reads the en table directly, independent of language negotiation.
    private func english(_ key: String) -> String? {
        let path = L10n.bundle.path(forResource: "Localizable", ofType: "strings",
                                    inDirectory: nil, forLocalization: "en")!
        return (NSDictionary(contentsOfFile: path) as! [String: String])[key]
    }

    func testLookupIsHealthy() {
        // A key that exists resolves to something other than itself...
        XCTAssertNotEqual(L10n.t("menu.quit"), "menu.quit")
        // ...and a missing key falls back to the key.
        XCTAssertEqual(L10n.t("definitely.not.a.key"), "definitely.not.a.key")
    }

    func testEnglishBaseValues() {
        XCTAssertEqual(english("menu.quit"), "Quit Claude RC Manager")
        XCTAssertEqual(english("status.running"), "● running")
        XCTAssertEqual(english("reason.exited"), "exited, status %d")
    }

    func testDisplayReasonMapsAllShapes() {
        // Both sides go through L10n.t, so these hold in every language.
        XCTAssertEqual(L10n.displayReason("claude not found"), L10n.t("reason.claudeNotFound"))
        XCTAssertEqual(L10n.displayReason("not logged in"), L10n.t("reason.notLoggedIn"))
        XCTAssertEqual(L10n.displayReason("folder missing"), L10n.t("reason.folderMissing"))
        XCTAssertEqual(L10n.displayReason("crash loop — check log"), L10n.t("reason.crashLoop"))
        XCTAssertEqual(L10n.displayReason("launch error"), L10n.t("reason.launchError"))
        XCTAssertEqual(L10n.displayReason("exited, status 3"), L10n.t("reason.exited", Int32(3)))
        XCTAssertEqual(L10n.displayReason("something new"), "something new")
        // Guard against the tautology trap: the mapped keys must exist.
        XCTAssertNotEqual(L10n.t("reason.claudeNotFound"), "reason.claudeNotFound")
    }
}
```

(Adjust key names to the final inventory.)

- [ ] **Step 7:** `swift build` (warning-free) + `swift test` all green;
existing tests must pass unchanged (internal identifiers untouched).

- [ ] **Step 8: Commit** — `git commit -m "Extract UI strings into an English base catalog"`

---

### Task 2: Key-parity test

**Files:**
- Create: `Tests/ClaudeRCManagerTests/LocalizationParityTests.swift`

- [ ] **Step 1: Write the parity test.** Two probe-verified traps: a
runtime-discovered locale set makes the test pass when a locale is
missing entirely, and `paths(forResourcesOfType:)` returns only the
NEGOTIATED localization's file, not one per language. Therefore:

```swift
let expected: Set<String> = ["en", "de", "fr", "es", "it", "ja", "zh-hans"]
// (zh-hans lowercase: SwiftPM lowercases lproj names in the bundle)

func keys(_ locale: String) throws -> Set<String> {
    let path = try XCTUnwrap(L10n.bundle.path(
        forResource: "Localizable", ofType: "strings",
        inDirectory: nil, forLocalization: locale),
        "\(locale).lproj/Localizable.strings missing")
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    return Set(try XCTUnwrap(plist as? [String: String]).keys)
}
```

Assert: `Set(L10n.bundle.localizations).isSuperset(of: expected)`; the
`en` key set is non-empty; every other expected locale's key set equals
`en`'s exactly (missing AND extra fail, message names locale + keys).
Until Tasks 3/4 land, restrict `expected` to `["en"]` with a TODO — the
translation tasks each extend it (so the test is red if a task forgets).

Additionally, per key: the multiset of format specifiers (conversion
chars after stripping `%n$` positions) must match `en`'s — a translation
that drops or retypes a `%@`/`%d` corrupts `String(format:)` at runtime.

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
- [ ] **Step 2:** Extend the parity test's `expected` set by these four
locales; `swift test` green.
- [ ] **Step 3: Commit** — `git commit -m "Add German, French, Spanish, Italian translations"`

---

### Task 4: Translations — ja, zh-Hans

**Files:**
- Create: `Sources/ClaudeRCManager/Resources/{ja,zh-Hans}.lproj/Localizable.strings`

- [ ] **Step 1:** Translate every key. CJK rules binding: no ASCII spaces
around interpolations mid-sentence, CJK punctuation (、。), Apple's own
localized pane names. Keep the status glyphs (`○ ● ◐ ✕`) exactly as in en.
The SOURCE directory is `zh-Hans.lproj` (SwiftPM lowercases it in the
emitted bundle; the parity test expects `zh-hans`).
- [ ] **Step 2:** Extend the parity `expected` set to the full seven;
`swift test` green.
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

The emitted bundle layout is FLAT (probe-verified:
`<bundle>/{en,de,…}.lproj/Localizable.strings`, no `Contents/`), and
SwiftPM lowercases `zh-Hans` → `zh-hans`:

```makefile
	mkdir -p "$(APP_DIR)/Contents/Resources"
	for lproj in "$(BUILD_DIR)/ClaudeRCManager_ClaudeRCManager.bundle/"*.lproj; do \
		cp -R "$$lproj" "$(APP_DIR)/Contents/Resources/"; \
	done
	for lang in en de fr es it ja zh-hans; do \
		test -f "$(APP_DIR)/Contents/Resources/$$lang.lproj/Localizable.strings" \
			|| { echo "missing $$lang.lproj/Localizable.strings"; exit 1; }; \
		cp "Resources/InfoPlist/$$lang.lproj/InfoPlist.strings" \
			"$(APP_DIR)/Contents/Resources/$$lang.lproj/"; \
	done
```

The `Resources/InfoPlist/` directories use the lowercase `zh-hans.lproj`
name to match. Recipe lines are TABs. `codesign` stays the last step.
Also add `CFBundleDevelopmentRegion` = `en` to `Resources/Info.plist`
(the base-language declaration for bundle negotiation).

- [ ] **Step 2:** `make app` succeeds; `codesign --verify --strict` exit 0;
all seven `.lproj` dirs present in `Contents/Resources/` with both files.
Negative check: temporarily move one `.lproj` out of the emitted SwiftPM
bundle, run `make app`, assert it exits non-zero; restore.
- [ ] **Step 3: Commit** — `git commit -m "Ship localizations in the app bundle"`

---

### Task 7: Main-spec amendments + README note

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-claude-rc-manager-design.md`
- Modify: `README.md`

- [ ] **Step 1:** Amend the main spec per the localization spec's
"Main-spec amendments" section (UI-language line; `exited (status N)` →
`exited, status N`). Also amend the localization spec's InfoPlist path
to the implemented layout (`Resources/InfoPlist/<lang>.lproj/`, lowercase
`zh-hans`).
- [ ] **Step 2:** README: one sentence under Usage — the app follows the
macOS system language; list the seven languages.
- [ ] **Step 3: Commit** — `git commit -m "Record localization in spec and README"`

---

### Task 8: Verification

- [ ] **Step 1:** `swift build` warning-free, `swift test` all green.
- [ ] **Step 2:** `make app`; then verify the assembled bundle headlessly
with a scratchpad Swift probe. Probe-verified facts: a bundle loaded via
`Bundle(path:)` does NOT negotiate against process language settings —
`localizedString(forKey:)` on it returns English regardless. The honest
headless checks are:

```swift
let b = Bundle(path: appPath)!
// negotiation input is complete:
assert(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["de"]) == ["de"])
assert(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["zh-Hans"]) == ["zh-hans"])
assert(Bundle.preferredLocalizations(from: b.localizations, forPreferences: ["pt-BR"]) == ["en"])
// and the shipped tables hold the right values (targeted read):
let de = b.path(forResource: "Localizable", ofType: "strings",
                inDirectory: nil, forLocalization: "de")!
assert((NSDictionary(contentsOfFile: de) as! [String: String])["menu.quit"] != nil)
```
- [ ] **Step 3:** Hand off to Sven: reinstall, spot-check German +
one CJK language visually (menu + one alert), confirm nothing regressed
in English.
