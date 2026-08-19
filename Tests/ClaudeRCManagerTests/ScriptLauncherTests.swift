import XCTest
@testable import ClaudeRCManager

/// Lock-guarded accumulator for data delivered on the pty reader thread.
/// A plain `var` captured by the @Sendable output callback is a concurrent
/// mutation of a captured variable (an error in Swift 6); the lock lives
/// inside the reference type instead, with identical semantics.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }; return data
    }
}

final class ScriptLauncherTests: XCTestCase {
    /// Polls for the inner pid, which resolves asynchronously via pgrep.
    private func waitForInnerPid(_ server: RunningServer) -> pid_t? {
        for _ in 0..<30 {
            if let pid = server.innerPid { return pid }
            usleep(100_000)
        }
        return nil
    }

    /// True once `pid` no longer exists (kill 0 asks without signaling).
    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = Darwin.kill(pid, 0)
            let err = errno
            if result == -1 && err == ESRCH { return true }
            usleep(100_000)
        }
        return false
    }

    func testLaunchResolvesInnerPidAndStops() throws {
        let launcher = ScriptLauncher()
        let exited = expectation(description: "exit")
        let server = try launcher.launch(
            argv: ["/usr/bin/script", "-q", "/dev/null", "/bin/sleep", "30"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in exited.fulfill() })

        // Inner pid resolves within ~2 s.
        let inner = try XCTUnwrap(waitForInnerPid(server), "inner pid must resolve")

        server.stop(gracePeriod: 2)
        wait(for: [exited], timeout: 5)
        // The inner sleep itself must be gone, not just script.
        XCTAssertTrue(waitUntilGone(inner), "inner process must be gone after stop")
    }

    /// script exits the moment its child detaches, so escalation may not key
    /// on script's liveness: a child that ignores SIGTERM must still be
    /// SIGKILLed once the grace period is over.
    func testTermIgnoringChildIsKilledAfterGracePeriod() throws {
        let launcher = ScriptLauncher()
        let server = try launcher.launch(
            argv: ["/usr/bin/script", "-q", "/dev/null",
                   "/bin/bash", "-c", "trap '' TERM HUP; sleep 60"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in })

        let inner = try XCTUnwrap(waitForInnerPid(server), "inner pid must resolve")

        server.stop(gracePeriod: 1)
        XCTAssertTrue(waitUntilGone(inner),
                      "inner process must be SIGKILLed after the grace period")
    }

    /// End to end through the real pipeline: pty output -> onOutput -> LogWriter
    /// -> file on disk.
    func testChildOutputReachesTheLogFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("server.log")
        let writer = try LogWriter(url: logURL)

        let received = LockedData()
        let exited = expectation(description: "exit")
        let launcher = ScriptLauncher()
        let server = try launcher.launch(
            argv: ["/usr/bin/script", "-q", "/dev/null", "/bin/echo", "hello"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { data in
                writer.append(data)
                received.append(data)
            },
            onExit: { _ in exited.fulfill() })

        wait(for: [exited], timeout: 10)

        // The last pty read can land just after the exit callback.
        var sawOutput = false
        for _ in 0..<30 {
            sawOutput = String(decoding: received.snapshot(), as: UTF8.self).contains("hello")
            if sawOutput { break }
            usleep(100_000)
        }
        XCTAssertTrue(sawOutput, "pty output must reach the output callback")

        writer.close()  // flushes the carry-over
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("hello"), "log file must contain the child's output, got: \(text)")
        XCTAssertFalse(server.pids.isEmpty)
    }
}
