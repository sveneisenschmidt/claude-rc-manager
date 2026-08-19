import XCTest
@testable import ClaudeRCManager

final class StatusIconTests: XCTestCase {
    func testWarningBeatsEverything() {
        XCTAssertEqual(StatusIcon.bucket(states: [.running, .failed("x")],
                                         healthy: true), .warning)
        XCTAssertEqual(StatusIcon.bucket(states: [.running], healthy: false), .warning)
    }

    func testActiveWhenAnythingRuns() {
        for s in [ServerState.starting, .running, .stopping, .restarting] {
            XCTAssertEqual(StatusIcon.bucket(states: [.stopped, s], healthy: true), .active)
        }
    }

    func testNeutralOtherwise() {
        XCTAssertEqual(StatusIcon.bucket(states: [.stopped, .ended], healthy: true), .neutral)
        XCTAssertEqual(StatusIcon.bucket(states: [], healthy: true), .neutral)
    }
}
