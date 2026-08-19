import XCTest
@testable import ClaudeRCManager

final class ClaudeCLITests: XCTestCase {
    func testRunReturnsStdout() {
        let data = ClaudeCLI.run(["/bin/echo", "hi"], timeout: 5)
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "hi\n")
    }

    func testRunTimesOut() {
        let start = Date()
        XCTAssertNil(ClaudeCLI.run(["/bin/sleep", "30"], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunNonzeroExitReturnsNil() {
        XCTAssertNil(ClaudeCLI.run(["/usr/bin/false"], timeout: 5))
    }

    /// Regression: a child that traps and ignores SIGTERM must still be
    /// gone shortly after the timeout, and run() must return promptly
    /// rather than blocking on a leaked read. The child's pid is found
    /// independently via pgrep -f, not read back from run() internals.
    func testRunTimeoutDoesNotLeakChildOrThread() throws {
        let marker = "claude-cli-timeout-test-\(UUID().uuidString)"
        let exp = expectation(description: "run returns")
        var result: Data? = Data([0]) // sentinel; must become nil
        var elapsed: TimeInterval = 0
        let start = Date()

        DispatchQueue.global().async {
            result = ClaudeCLI.run(
                ["/bin/sh", "-c", "trap '' TERM; sleep 30 # \(marker)"],
                timeout: 1)
            elapsed = Date().timeIntervalSince(start)
            exp.fulfill()
        }

        // Give the shell a moment to install the trap and start sleeping,
        // then find its pid independently of the call under test.
        usleep(300_000)
        let pgrepOut = ClaudeCLI.run(["/usr/bin/pgrep", "-f", marker], timeout: 2)
        let pid = String(data: pgrepOut ?? Data(), encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { pid_t($0) }
            .first
        XCTAssertNotNil(pid, "must find the running child via pgrep before it is killed")

        wait(for: [exp], timeout: 5)
        XCTAssertNil(result, "timeout must return nil")
        XCTAssertLessThan(elapsed, 3, "timeout path must not block on the leaked read")

        if let pid {
            // SIGTERM is trapped away; run() must have escalated to SIGKILL.
            usleep(300_000)
            XCTAssertEqual(Darwin.kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
}
