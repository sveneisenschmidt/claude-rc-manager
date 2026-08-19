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
    func launch(argv: [String], workingDirectory: String) throws -> RunningServer {
        if let error { throw error }
        launchCount += 1
        let s = FakeServer()
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
            backoffScale: 0.01)
        return (sp, launcher)
    }

    /// onExit hops onto the main actor via an enqueued Task; yield so the
    /// queued task runs before asserting. Yielding rather than sleeping keeps
    /// this deterministic and, more importantly, takes no wall-clock time:
    /// a sleep long enough to be safe would also let the scaled backoff timer
    /// fire, hiding the `.restarting` state the tests assert on.
    func drainMainQueue() async throws {
        for _ in 0..<3 { await Task.yield() }
    }

    func testStartReachesRunningAfterReadinessDelay() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sp.state, .running)
    }

    func testUserStopGoesToStoppedWithoutRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        sp.stop()
        XCTAssertEqual(sp.state, .stopping)
        launcher.servers[0].exitNow(0)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .stopped)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testUnexpectedExitSchedulesRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(1)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .restarting)
    }

    func testStopDuringRestartingCancelsTimerAndStops() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(1)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .restarting)
        sp.stop()
        XCTAssertEqual(sp.state, .stopped)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(launcher.launchCount, 1) // no restart fired
    }

    func testCrashLoopPauseThenManualStartClears() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(1) // fast exit 1 -> backoff restart
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[1].exitNow(1) // fast exit 2 -> backoff restart
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[2].exitNow(1) // fast exit 3 -> pause
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .failed("crash loop — check log"))
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 4)
    }

    func testSessionModeExitZeroIsEnded() async throws {
        let (sp, launcher) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(0)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .ended)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testAutoRestartOffGoesToFailed() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(3)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .failed("exited, status 3"))
    }

    func testPreflightFailureBlocksRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        sp.preflight = { "not logged in" }
        launcher.servers[0].exitNow(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sp.state, .failed("not logged in"))
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testLaunchErrorIsFailed() {
        let (sp, launcher) = makeSUT()
        launcher.error = NSError(domain: "x", code: 1)
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .failed("launch error"))
    }
}
