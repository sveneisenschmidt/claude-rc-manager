import XCTest
@testable import ClaudeRCManager

final class L10nTests: XCTestCase {
    /// Reads the en table directly, independent of language negotiation:
    /// under `swift test` the module bundle negotiates against the system
    /// language, so `L10n.t` may legitimately return a translation.
    private func english(_ key: String) throws -> String? {
        let path = try XCTUnwrap(L10n.bundle.path(
            forResource: "Localizable", ofType: "strings",
            inDirectory: nil, forLocalization: "en"))
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        return table[key]
    }

    func testLookupIsHealthy() {
        // A key that exists resolves to something other than itself...
        XCTAssertNotEqual(L10n.t("menu.quit"), "menu.quit")
        // ...and a missing key falls back to the key.
        XCTAssertEqual(L10n.t("definitely.not.a.key"), "definitely.not.a.key")
    }

    func testEnglishBaseValues() throws {
        XCTAssertEqual(try english("menu.quit"), "Quit Claude RC Manager")
        XCTAssertEqual(try english("menu.addFolder"), "Add Folder…")
        XCTAssertEqual(try english("status.running"), "● running")
        XCTAssertEqual(try english("status.restarting"), "◐ restarting…")
        XCTAssertEqual(try english("status.failed"), "✕ failed (%@)")
        XCTAssertEqual(try english("reason.exited"), "exited, status %d")
        XCTAssertEqual(try english("external.row"), "%@ — running (external)")
        XCTAssertEqual(try english("external.pidFallback"), "pid %@")
        XCTAssertEqual(try english("settings.title"), "%@ — Settings")
        XCTAssertEqual(try english("a11y.warning"), "Claude RC Manager — warning")
        XCTAssertEqual(try english("alert.sessions.quit.title.other"),
                       "Quit with %d active sessions?")
        XCTAssertEqual(try english("menu.sessions.one"), "· 1 session")
    }

    /// Every scope bullet must map to a key; a typo'd key silently renders
    /// as its own name in the UI, so assert the whole inventory exists.
    func testEveryInventoryKeyIsPresent() throws {
        let keys = [
            "menu.addFolder", "menu.startAll", "menu.stopAll", "menu.startAtLogin",
            "menu.startAtLogin.tooltip", "menu.quit", "menu.openLogin", "menu.start",
            "menu.stop", "menu.openLog", "menu.settings", "menu.remove",
            "warning.cliNotFound", "warning.notLoggedIn", "warning.configCorrupt",
            "warning.configUnreadable",
            "external.header", "external.row", "external.pidFallback",
            "status.stopped", "status.starting", "status.running", "status.stopping",
            "status.restarting", "status.ended", "status.failed",
            "reason.claudeNotFound", "reason.notLoggedIn", "reason.folderMissing",
            "reason.crashLoop", "reason.launchError", "reason.exited",
            "settings.title", "settings.name", "settings.path", "settings.spawnMode",
            "settings.createSessionInDir", "settings.capacity", "settings.permissionMode",
            "settings.permissionMode.cliDefault", "settings.extraArgs", "settings.autostart",
            "settings.autoRestart", "settings.applyHint", "settings.save", "settings.cancel",
            "alert.terminal.title", "alert.terminal.body",
            "alert.remove.title", "alert.remove.body", "alert.remove.confirm",
            "alert.remove.cancel", "alert.duplicateFolder.title",
            "alert.saveFailed.title", "alert.saveFailed.unreadable", "alert.saveFailed.body",
            "alert.loginItem.title", "alert.loginItem.requiresApproval",
            "alert.sessions.quit.title.one", "alert.sessions.quit.title.other",
            "alert.sessions.stop.title.one", "alert.sessions.stop.title.other",
            "alert.sessions.body.list",
            "alert.sessions.confirm.quit", "alert.sessions.confirm.stop",
            "alert.sessions.cancel",
            "alert.remove.sessions.one", "alert.remove.sessions.other",
            "menu.sessions.one", "menu.sessions.other",
            "a11y.warning", "a11y.active", "a11y.idle",
        ]
        for key in keys {
            XCTAssertNotNil(try english(key), "missing en value for \(key)")
        }
    }

    func testFormattingSubstitutesArguments() {
        // Language-agnostic: the argument must survive into the result.
        // Numbers are formatted with Locale.current (per the helper), so a
        // four-digit value would carry a locale grouping separator; assert
        // with values that render identically in every locale.
        XCTAssertTrue(L10n.t("settings.title", "demo").contains("demo"))
        // %@ with a pre-rendered String: pids never get locale digit grouping.
        XCTAssertTrue(L10n.t("external.pidFallback", String(4711)).contains("4711"))
        XCTAssertTrue(L10n.t("settings.capacity", String(12)).contains("12"))
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
        XCTAssertNotEqual(L10n.t("reason.exited"), "reason.exited")
    }
}
