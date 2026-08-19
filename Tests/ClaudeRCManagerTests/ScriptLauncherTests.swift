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
}
