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

/// Counts exit callbacks from the launcher's queue. A counter, not an
/// XCTestExpectation: a second fulfillment of a one-shot expectation is what
/// this asserts must never happen, and that would fail the run by crashing it.
private final class ExitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}

final class PtyLauncherTests: XCTestCase {
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
        let launcher = PtyLauncher()
        let exited = expectation(description: "exit")
        let server = try launcher.launch(
            argv: ["/bin/sleep", "30"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in exited.fulfill() })

        // The pid is known at spawn time now — a smoke assertion.
        let inner = try XCTUnwrap(server.innerPid, "inner pid must be known")
        XCTAssertEqual(server.pids, [inner])

        server.stop(gracePeriod: 2)
        wait(for: [exited], timeout: 5)
        XCTAssertTrue(waitUntilGone(inner), "child must be gone after stop")
    }

    /// The CLI ignores SIGTERM entirely (verified 2026-08-19), so escalation
    /// may not key on the child reacting to it: a child that ignores SIGTERM
    /// must still be SIGKILLed once the grace period is over.
    func testTermIgnoringChildIsKilledAfterGracePeriod() throws {
        let launcher = PtyLauncher()
        let server = try launcher.launch(
            argv: ["/bin/bash", "-c", "trap '' TERM HUP; sleep 60"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in })

        let inner = try XCTUnwrap(server.innerPid, "inner pid must be known")

        server.stop(gracePeriod: 1)
        XCTAssertTrue(waitUntilGone(inner),
                      "child must be SIGKILLed after the grace period")
    }

    /// The regression this launcher exists for: `script` forwarded the stdin
    /// EOF into the pty as Ctrl-D and the CLI exited seconds after start. A pty
    /// we own and never write to gives the child no EOF at all.
    func testChildReadingStdinDoesNotSeeEOF() throws {
        let launcher = PtyLauncher()
        let exited = expectation(description: "exit")
        exited.isInverted = true
        let server = try launcher.launch(
            argv: ["/bin/cat"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in exited.fulfill() })
        let pid = try XCTUnwrap(server.innerPid)

        // /bin/cat exits immediately on stdin EOF; two seconds later it must
        // still be sitting on the pty.
        wait(for: [exited], timeout: 2)
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "child must still be alive")

        server.stop(gracePeriod: 1)
        XCTAssertTrue(waitUntilGone(pid), "child must be gone after stop")
    }

    /// A stop must outlive its owner: ServerManager drops the ServerProcess
    /// (and with it the only strong reference to the server) as soon as a
    /// folder is removed, right after asking it to stop. A weak capture in the
    /// stop path loses both the TERM and the SIGKILL escalation and leaves the
    /// CLI running forever.
    func testStopSurvivesOwnerRelease() throws {
        let launcher = PtyLauncher()
        var server: RunningServer? = try launcher.launch(
            argv: ["/bin/sleep", "30"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in })
        let pid = try XCTUnwrap(server?.innerPid)

        server?.stop(gracePeriod: 0.2)
        server = nil  // owner gone before the escalation fires

        XCTAssertTrue(waitUntilGone(pid),
                      "the escalation must survive the owner being released")
    }

    /// ServerProcess treats the exit callback as the end of a run (it releases
    /// the log writer and may schedule a restart), so a second call would act
    /// on the next run. The probe and the process source both race to report
    /// the same exit; exactly one of them may win.
    func testExitIsReportedExactlyOnce() throws {
        let counter = ExitCounter()
        let launcher = PtyLauncher()
        let server = try launcher.launch(
            argv: ["/bin/echo", "bye"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in },
            onExit: { _ in counter.increment() })
        let pid = try XCTUnwrap(server.innerPid)
        XCTAssertTrue(waitUntilGone(pid), "child must exit on its own")

        // Redundant stop/kill after the exit: neither may produce a second
        // report (nor signal a recycled pid).
        server.stop(gracePeriod: 0.1)
        server.kill()
        usleep(600_000)
        XCTAssertEqual(counter.value, 1, "onExit must fire exactly once")
    }

    /// Every server's pty master must stay inside this process: a leaked
    /// master in another server's child holds the first server's pty open for
    /// as long as that child lives.
    func testChildDoesNotInheritOtherServersDescriptors() throws {
        let launcher = PtyLauncher()
        let first = try launcher.launch(
            argv: ["/bin/cat"],  // keeps its pty (and its master) alive
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { _ in }, onExit: { _ in })
        defer { first.stop(gracePeriod: 0.1) }

        let listing = LockedData()
        let exited = expectation(description: "exit")
        _ = try launcher.launch(
            argv: ["/bin/sh", "-c", "ls -l /dev/fd"],
            workingDirectory: NSTemporaryDirectory(),
            onOutput: { listing.append($0) },
            onExit: { _ in exited.fulfill() })
        wait(for: [exited], timeout: 10)

        // Only the child's own stdio may be a terminal; `ls` contributes a
        // couple of plain directory descriptors of its own. A leaked master
        // (or slave) would show up as a fourth tty-owned character device.
        let output = String(decoding: listing.snapshot(), as: UTF8.self)
        let ttys = output.components(separatedBy: "tty").count - 1
        XCTAssertEqual(ttys, 3, "child inherited a pty it should not have:\n\(output)")
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
        let launcher = PtyLauncher()
        let server = try launcher.launch(
            argv: ["/bin/echo", "hello"],
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
