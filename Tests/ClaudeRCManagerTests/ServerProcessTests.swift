import XCTest
@testable import ClaudeRCManager

// FakeServer, FakeLauncher and waitFor live in TestSupport.swift.

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

    func testStartReachesRunningAfterReadinessDelay() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 1)
        try await waitFor({ sp.state == .running }, "readiness delay must promote to running")
    }

    func testUserStopGoesToStoppedWithoutRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        sp.stop()
        XCTAssertEqual(sp.state, .stopping)
        launcher.servers[0].exitNow(0)
        try await waitFor({ sp.state == .stopped }, "user stop must end in stopped")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testUnexpectedExitSchedulesRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.state == .restarting }, "unexpected exit must schedule a restart")
    }

    func testStopDuringRestartingCancelsTimerAndStops() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.state == .restarting }, "unexpected exit must schedule a restart")
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
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(1) // fast exit 1 -> backoff restart
        try await waitFor({ launcher.launchCount == 2 }, "first backoff restart must launch")
        launcher.servers[1].exitNow(1) // fast exit 2 -> backoff restart
        try await waitFor({ launcher.launchCount == 3 }, "second backoff restart must launch")
        launcher.servers[2].exitNow(1) // fast exit 3 -> pause
        try await waitFor({ sp.state == .failed("crash loop — check log") },
                      "third fast exit must pause auto-restart")
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 4)
    }

    func testSessionModeExitZeroIsEnded() async throws {
        let (sp, launcher) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(0)
        try await waitFor({ sp.state == .ended }, "session mode exit is expected, not a crash")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testAutoRestartOffGoesToFailed() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].exitNow(3)
        try await waitFor({ sp.state == .failed("exited, status 3") },
                      "auto-restart off must surface the exit status")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testPreflightFailureBlocksRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        sp.preflight = { "not logged in" }
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.state == .failed("not logged in") },
                      "a failing preflight must block the scheduled restart")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testKillNowSuppressesRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        sp.killNow()
        XCTAssertTrue(launcher.servers[0].killed)
        launcher.servers[0].exitNow(9)
        try await waitFor({ sp.state == .stopped }, "kill-induced exit must not restart")
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testOutputFlowsThroughToLogFile() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("hello\n".utf8))
        sp.stop()
        launcher.servers[0].exitNow(0)
        try await waitFor({ sp.state == .stopped }, "stop must complete")
        let content = try String(contentsOf: sp.logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("hello"), "log file must carry the output")
    }

    func testLaunchErrorIsFailed() {
        let (sp, launcher) = makeSUT()
        launcher.error = NSError(domain: "x", code: 1)
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .failed("launch error"))
    }

    // MARK: session count

    func testCountFromOutputIsApplied() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ sp.sessionCount == 2 }, "reported count must be applied")
        XCTAssertEqual(sp.activeSessions, 2)
    }

    func testUnknownCountMeansNoSessions() async throws {
        let (sp, _) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        XCTAssertNil(sp.sessionCount)
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testStoppedServerHasNoSessions() {
        let (sp, _) = makeSUT()
        XCTAssertEqual(sp.state, .stopped)
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testSessionSpawnModeCountsAsOne() async throws {
        let (sp, _) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        XCTAssertNil(sp.sessionCount)
        XCTAssertEqual(sp.activeSessions, 1)
    }

    func testSpawnModeIsReadFromTheRunSnapshot() async throws {
        let (sp, _) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        var edited = sp.folder
        edited.spawnMode = .worktree
        sp.update(folder: edited)
        XCTAssertEqual(sp.activeSessions, 1,
                       "an edit during the run must not change how this run counts")
    }

    func testCountIsClearedOnExit() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 3/32".utf8))
        try await waitFor({ sp.sessionCount == 3 }, "reported count must be applied")
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.sessionCount == nil }, "exit must clear the count")
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testWaitingForARestartHasNoSessions() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ sp.sessionCount == 2 }, "reported count must be applied")
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.state == .restarting }, "must schedule a restart")
        // .restarting counts as active, but no process is running.
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testReportFromASupersededRunIsIgnored() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        let firstRun = launcher.servers[0]
        firstRun.exitNow(1)
        try await waitFor({ sp.state == .failed("exited, status 1") }, "must fail")
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "second run must reach running")
        // The old run's pty chunk arrives late.
        firstRun.onOutput?(Data("Capacity: 9/32".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(sp.sessionCount, "a superseded run must not set the count")
    }

    func testStoppingReportsNoSessions() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ sp.sessionCount == 2 }, "reported count must be applied")
        sp.stop()
        XCTAssertEqual(sp.state, .stopping)
        XCTAssertEqual(sp.activeSessions, 0,
                       "a confirmed stop must not be warned about a second time")
    }
}
