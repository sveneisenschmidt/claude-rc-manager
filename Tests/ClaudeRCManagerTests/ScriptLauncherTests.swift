import XCTest
@testable import ClaudeRCManager

final class ScriptLauncherTests: XCTestCase {
    func testLaunchResolvesInnerPidAndStops() throws {
        let launcher = ScriptLauncher()
        let server = try launcher.launch(
            argv: ["/usr/bin/script", "-q", "/dev/null", "/bin/sleep", "30"],
            workingDirectory: NSTemporaryDirectory())

        let exited = expectation(description: "exit")
        server.onExit = { _ in exited.fulfill() }

        // Inner pid resolves within ~2 s.
        var inner: pid_t?
        for _ in 0..<30 {
            if let pid = server.innerPid { inner = pid; break }
            usleep(100_000)
        }
        XCTAssertNotNil(inner, "inner pid must resolve")

        server.stop(gracePeriod: 2)
        wait(for: [exited], timeout: 5)
        // The inner sleep itself must be gone (kill 0 = existence probe).
        usleep(200_000)
        XCTAssertEqual(Darwin.kill(inner!, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    /// script exits the moment its child detaches, so escalation may not key
    /// on script's liveness: a child that ignores SIGTERM must still be
    /// SIGKILLed once the grace period is over.
    func testTermIgnoringChildIsKilledAfterGracePeriod() throws {
        let launcher = ScriptLauncher()
        let server = try launcher.launch(
            argv: ["/usr/bin/script", "-q", "/dev/null",
                   "/bin/bash", "-c", "trap '' TERM HUP; sleep 60"],
            workingDirectory: NSTemporaryDirectory())

        var inner: pid_t?
        for _ in 0..<30 {
            if let pid = server.innerPid { inner = pid; break }
            usleep(100_000)
        }
        let innerPid = try XCTUnwrap(inner, "inner pid must resolve")

        server.stop(gracePeriod: 1)

        // SIGTERM is ignored; the grace-period SIGKILL must still land.
        var gone = false
        for _ in 0..<30 {
            if Darwin.kill(innerPid, 0) == -1 && errno == ESRCH { gone = true; break }
            usleep(100_000)
        }
        XCTAssertTrue(gone, "inner process must be SIGKILLed after the grace period")
    }
}
