import XCTest
@testable import ClaudeRCManager

final class FakeServer: RunningServer {
    var innerPid: pid_t? = 4242
    var pids: [pid_t] { [111, 4242] } // 111 stands in for the script pid
    var onExit: ((Int32) -> Void)?
    var onOutput: ((Data) -> Void)?
    var stopped = false
    var killed = false
    func stop(gracePeriod: TimeInterval) { stopped = true }
    func kill() { killed = true }
    func exitNow(_ status: Int32) { onExit?(status) }
}

final class FakeLauncher: ProcessLaunching {
    var servers: [FakeServer] = []
    var launchCount = 0
    var error: Error?
    func launch(argv: [String], workingDirectory: String,
                onOutput: @escaping (Data) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> RunningServer
    {
        if let error { throw error }
        launchCount += 1
        let s = FakeServer()
        s.onOutput = onOutput
        s.onExit = onExit
        servers.append(s)
        return s
    }
}

@MainActor
final class ServerProcessTests: XCTestCase {
    func makeSUT(spawnMode: SpawnMode = .sameDir, autoRestart: Bool = true)
        -> (ServerProcess, FakeLauncher)
    {
        var f = FolderConfig(path: NSTemporaryDirectory())
        f.spawnMode = spawnMode
        f.autoRestart = autoRestart
        let launcher = FakeLauncher()
        let sp = ServerProcess(
            folder: f, launcher: launcher,
            logDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            claudePath: "/bin/echo",
            readinessDelay: 0.05,
            backoffScale: 0.2)
        return (sp, launcher)
    }

    /// Polls instead of sleeping a fixed span: callbacks hop to the main actor
    /// and timers fire on their own schedule, so an assertion right after a
    /// fixed sleep is a race in both directions (too early, or so late that a
    /// transient state such as `.restarting` is already gone).
    func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3,
                 _ message: String,
                 file: StaticString = #filePath, line: UInt = #line) async
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    func testStartReachesRunningAfterReadinessDelay() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 1)
        await waitFor({ sp.state == .running }, "readiness delay must promote to running")
    }

    func testUserStopGoesToStoppedWithoutRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        sp.stop()
        XCTAssertEqual(sp.state, .stopping)
        launcher.servers[0].exitNow(0)
        await waitFor({ sp.state == .stopped }, "user stop must end in stopped")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testUnexpectedExitSchedulesRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(1)
        await waitFor({ sp.state == .restarting }, "unexpected exit must schedule a restart")
    }

    func testStopDuringRestartingCancelsTimerAndStops() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(1)
        await waitFor({ sp.state == .restarting }, "unexpected exit must schedule a restart")
        sp.stop()
        XCTAssertEqual(sp.state, .stopped)
        // Well past the scaled backoff delay: the cancelled timer stays silent.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(launcher.launchCount, 1) // no restart fired
        XCTAssertEqual(sp.state, .stopped)
    }

    func testCrashLoopPauseThenManualStartClears() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(1) // fast exit 1 -> backoff restart
        await waitFor({ launcher.launchCount == 2 }, "first backoff restart must launch")
        launcher.servers[1].exitNow(1) // fast exit 2 -> backoff restart
        await waitFor({ launcher.launchCount == 3 }, "second backoff restart must launch")
        launcher.servers[2].exitNow(1) // fast exit 3 -> pause
        await waitFor({ sp.state == .failed("crash loop — check log") },
                      "third fast exit must pause auto-restart")
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 4)
    }

    func testSessionModeExitZeroIsEnded() async throws {
        let (sp, launcher) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(0)
        await waitFor({ sp.state == .ended }, "session mode exit is expected, not a crash")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testAutoRestartOffGoesToFailed() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(3)
        await waitFor({ sp.state == .failed("exited, status 3") },
                      "auto-restart off must surface the exit status")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testPreflightFailureBlocksRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        await waitFor({ sp.state == .running }, "must reach running")
        sp.preflight = { "not logged in" }
        launcher.servers[0].exitNow(1)
        await waitFor({ sp.state == .failed("not logged in") },
                      "a failing preflight must block the scheduled restart")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testLaunchErrorIsFailed() {
        let (sp, launcher) = makeSUT()
        launcher.error = NSError(domain: "x", code: 1)
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .failed("launch error"))
    }
}
