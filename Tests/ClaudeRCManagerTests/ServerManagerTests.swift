import XCTest
@testable import ClaudeRCManager

@MainActor
final class ServerManagerTests: XCTestCase {
    func makeSUT() -> (ServerManager, FakeLauncher) {
        let launcher = FakeLauncher()
        var config = AppConfig()
        var a = FolderConfig(path: NSTemporaryDirectory())
        a.autostart = true
        var b = FolderConfig(path: NSTemporaryDirectory() + "/nope-\(UUID())")
        b.autostart = true
        config.folders = [a, b]
        let mgr = ServerManager(
            config: config, launcher: launcher,
            logDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            readinessDelay: 0.05)
        return (mgr, launcher)
    }

    /// Polls instead of sleeping a fixed span: state changes ride on timers and
    /// main-actor hops, so a fixed sleep races in both directions.
    struct WaitTimeout: Error {}

    func waitFor(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3,
                 _ message: String,
                 file: StaticString = #filePath, line: UInt = #line) async throws
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail(message, file: file, line: line)
        throw WaitTimeout()
    }

    func testAutostartStartsOnlyExistingFolders() {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(mgr.processes[1].state, .failed("folder missing"))
    }

    func testAutostartSkippedWhenLoggedOut() {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: false)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(mgr.processes[0].state, .failed("not logged in"))
    }

    func testAutostartSkippedWhenClaudeMissing() {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: nil, loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(mgr.processes[0].state, .failed("claude not found"))
    }

    func testStopAllStopsRunning() async throws {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        mgr.stopAll()
        XCTAssertTrue(launcher.servers[0].stopped)
        XCTAssertEqual(mgr.processes[0].state, .stopping)
    }

    func testOwnPidsListsScriptAndInnerPids() {
        let (mgr, _) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(mgr.ownPids(), [111, 4242]) // FakeServer.pids
    }

    func testStartAllStartsStoppedFoldersOnly() async throws {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        // Folder 0 is running (not startable), folder 1 failed (startable but
        // its path is still missing), so no new launch may happen.
        mgr.startAll(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(mgr.processes[0].state, .running)
    }

    func testStartByIdStartsThatFolder() {
        let (mgr, launcher) = makeSUT()
        let id = mgr.processes[0].folder.id
        mgr.start(id: id, claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(mgr.processes[0].state, .starting)
        XCTAssertEqual(mgr.processes[1].state, .stopped)
    }

    func testSetFoldersKeepsProcessesAndStopsRemovedOnes() async throws {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        let kept = mgr.processes[0]
        var renamed = kept.folder
        renamed.name = "renamed"
        // Drop folder 1, keep folder 0 with edited settings.
        mgr.setFolders([renamed], claudePath: "/bin/true")
        XCTAssertEqual(mgr.processes.count, 1)
        XCTAssertTrue(mgr.processes[0] === kept, "same id must reuse its process")
        XCTAssertEqual(mgr.processes[0].folder.name, "renamed")
        XCTAssertEqual(launcher.launchCount, 1, "reuse must not relaunch")
    }

    func testSetFoldersStopsRemovedRunningServer() async throws {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        mgr.setFolders([], claudePath: nil)
        XCTAssertTrue(mgr.processes.isEmpty)
        XCTAssertTrue(launcher.servers[0].stopped, "removed folder's server must stop")
    }

    func testStatesAndAnyActive() async throws {
        let (mgr, _) = makeSUT()
        XCTAssertFalse(mgr.anyActive)
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        XCTAssertTrue(mgr.anyActive)
        XCTAssertEqual(mgr.states, [.running, .failed("folder missing")])
    }

    func testKillAllNowKillsRunningServers() async throws {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        mgr.killAllNow()
        XCTAssertTrue(launcher.servers[0].killed)
    }

    func testStateChangesNotifyManager() async throws {
        let (mgr, _) = makeSUT()
        var notifications = 0
        mgr.onAnyStateChange = { notifications += 1 }
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ notifications >= 2 }, "state changes must be forwarded")
    }

    func testManagerPreflightBlocksStart() {
        let (mgr, launcher) = makeSUT()
        mgr.preflight = { "not logged in" }
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(mgr.processes[0].state, .failed("not logged in"))
    }
}
