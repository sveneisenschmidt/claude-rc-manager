import XCTest
@testable import ClaudeRCManager

final class BackoffTests: XCTestCase {
    func testDelaySequenceCapsAt60() {
        var p = RestartPolicy()
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 2))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 4))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 8))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 16))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 32))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 60))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 60))
    }

    func testCrashLoopPausesOnThirdFastExit() {
        var p = RestartPolicy()
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 2), .restart(after: 2))
        XCTAssertEqual(p.recordExit(runDuration: 1), .crashLoopPause)
    }

    func testSlowExitResetsCrashLoopCounterButNotBackoff() {
        var p = RestartPolicy()
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 2))
        // 10 s run: not a fast exit, crash-loop counter resets,
        // backoff keeps growing (only a >= 5 min run resets it).
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 4))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 8))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 16))
        XCTAssertEqual(p.recordExit(runDuration: 1), .crashLoopPause)
    }

    func testStableRunResetsEverything() {
        var p = RestartPolicy()
        _ = p.recordExit(runDuration: 1)
        _ = p.recordExit(runDuration: 1)
        XCTAssertEqual(p.recordExit(runDuration: 301), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 2))
    }

    func testManualStartResets() {
        var p = RestartPolicy()
        _ = p.recordExit(runDuration: 1)
        _ = p.recordExit(runDuration: 1)
        p.reset()
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 1))
    }
}
