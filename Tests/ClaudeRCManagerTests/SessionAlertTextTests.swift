import XCTest
@testable import ClaudeRCManager

/// Language-agnostic on purpose: `swift test` negotiates the system
/// language, so the assertions check structure and substitution, not
/// English wording. The English wording itself is asserted in L10nTests.
final class SessionAlertTextTests: XCTestCase {
    func testTitleUsesTheSingularKeyForOne() {
        XCTAssertEqual(SessionAlertText.title(scope: .quit, count: 1),
                       L10n.t("alert.sessions.quit.title.one"))
        XCTAssertEqual(SessionAlertText.title(scope: .stop, count: 1),
                       L10n.t("alert.sessions.stop.title.one"))
    }

    func testTitleUsesThePluralKeyAndSubstitutesTheCount() {
        let title = SessionAlertText.title(scope: .quit, count: 3)
        XCTAssertEqual(title, L10n.t("alert.sessions.quit.title.other", Int32(3)))
        XCTAssertTrue(title.contains("3"))
    }

    func testQuitAndStopTitlesDiffer() {
        XCTAssertNotEqual(SessionAlertText.title(scope: .quit, count: 2),
                          SessionAlertText.title(scope: .stop, count: 2))
    }

    func testBodyEnumeratesFoldersWithTheirCounts() {
        let body = SessionAlertText.body(entries: [
            SessionEntry(name: "alpha", count: 2),
            SessionEntry(name: "beta", count: 1),
        ])
        XCTAssertTrue(body.contains("alpha (2), beta (1)"), body)
    }

    func testConfirmButtonDiffersByScope() {
        XCTAssertEqual(SessionAlertText.confirmButton(scope: .quit),
                       L10n.t("alert.sessions.confirm.quit"))
        XCTAssertNotEqual(SessionAlertText.confirmButton(scope: .quit),
                          SessionAlertText.confirmButton(scope: .stop))
    }

    func testMenuSuffixIsNilBelowOne() {
        XCTAssertNil(SessionAlertText.menuSuffix(count: 0))
        XCTAssertNotNil(SessionAlertText.menuSuffix(count: 1))
    }

    func testMenuSuffixSubstitutesThePluralCount() throws {
        let suffix = try XCTUnwrap(SessionAlertText.menuSuffix(count: 4))
        XCTAssertEqual(suffix, L10n.t("menu.sessions.other", Int32(4)))
    }

    func testRemoveSentenceIsNilWithoutSessions() {
        XCTAssertNil(SessionAlertText.removeSentence(count: 0))
        XCTAssertEqual(SessionAlertText.removeSentence(count: 1),
                       L10n.t("alert.remove.sessions.one"))
        XCTAssertEqual(SessionAlertText.removeSentence(count: 2),
                       L10n.t("alert.remove.sessions.other", Int32(2)))
    }

    /// The number the alert's threshold is read from, kept here so it is
    /// testable: the modal itself has no unit test.
    func testTotalCountsEveryFolder() {
        XCTAssertEqual(SessionAlertText.total(of: []), 0)
        let entries = [SessionEntry(name: "alpha", count: 2),
                       SessionEntry(name: "beta", count: 1)]
        XCTAssertEqual(SessionAlertText.total(of: entries), 3)
    }
}
