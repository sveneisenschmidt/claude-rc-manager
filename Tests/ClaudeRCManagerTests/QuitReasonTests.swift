import CoreServices
import XCTest
@testable import ClaudeRCManager

/// The Apple-event side cannot be driven from a test, so the verdict is
/// tested on its own: a wrong `true` would silently kill sessions, a wrong
/// `false` would put a modal in front of a logout.
final class QuitReasonTests: XCTestCase {
    func testLogoutRestartAndShutdownSkipTheWarning() {
        for code in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog,
                     kAERestart, kAEShowShutdownDialog, kAEShutDown]
        {
            XCTAssertTrue(AppDelegate.isSystemQuitReason(OSType(code)), "\(code)")
        }
    }

    func testAnythingElseStillAsks() {
        XCTAssertFalse(AppDelegate.isSystemQuitReason(0))
        XCTAssertFalse(AppDelegate.isSystemQuitReason(OSType(kAEQuitApplication)))
    }
}
