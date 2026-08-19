import XCTest
@testable import ClaudeRCManager

@MainActor
final class ServerManagerTests: XCTestCase {
    // FakeServer, FakeLauncher and waitFor live in TestSupport.swift.

    func validFolder(autostart: Bool = true) -> FolderConfig {
        var f = FolderConfig(path: NSTemporaryDirectory())
        f.autostart = autostart
        return f
    }

    func missingFolder(autostart: Bool = true) -> FolderConfig {
        var f = FolderConfig(path: NSTemporaryDirectory() + "/nope-\(UUID())")
        f.autostart = autostart
        return f
    }

    /// Default layout: folder 0 exists, folder 1 does not; both autostart.
    func makeSUT(folders: [FolderConfig]? = nil,
                 backoffScale: Double = 0.05) -> (ServerManager, FakeLauncher)
    {
        let launcher = FakeLauncher()
        var config = AppConfig()
        config.folders = folders ?? [validFolder(), missingFolder()]
        let mgr = ServerManager(
            config: config, launcher: launcher,
            logDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            readinessDelay: 0.05, backoffScale: backoffScale)
        return (mgr, launcher)
    }

    func testAutostartStartsOnlyExistingFolders() {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(mgr.processes[1].state, .failed("folder missing"))
    }

    func testAutostartSkipsFoldersWithoutTheFlag() {
        let (mgr, launcher) = makeSUT(folders: [validFolder(autostart: false)])
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(mgr.processes[0].state, .stopped)
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

    func testOwnPidsListsScriptAndInnerPidsOfEveryServer() async throws {
        let (mgr, launcher) = makeSUT(folders: [validFolder(), validFolder()])
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 2)
        let expected = Set(launcher.servers.flatMap(\.pids))
        XCTAssertEqual(expected.count, 4, "each server must have its own pid pair")
        XCTAssertEqual(mgr.ownPids(), expected)
    }

    func testOwnPidsIsEmptyWhenNothingRuns() {
        let (mgr, _) = makeSUT()
        XCTAssertTrue(mgr.ownPids().isEmpty)
    }

    func testStartAllStartsStoppedValidFolder() async throws {
        let (mgr, launcher) = makeSUT(folders: [validFolder(), validFolder(autostart: false)])
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        XCTAssertEqual(launcher.launchCount, 1)
        // Folder 0 is running (not startable); folder 1 is stopped and valid.
        mgr.startAll(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 2)
        XCTAssertEqual(mgr.processes[0].state, .running)
        XCTAssertEqual(mgr.processes[1].state, .starting)
    }

    func testStartAllClearsCrashLoopPauseAndRelaunches() async throws {
        let (mgr, launcher) = makeSUT(folders: [validFolder()])
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes[0].state == .running }, "must reach running")
        launcher.servers[0].exitNow(1) // fast exit 1 -> backoff restart
        try await waitFor({ launcher.launchCount == 2 }, "first backoff restart must launch")
        launcher.servers[1].exitNow(1) // fast exit 2 -> backoff restart
        try await waitFor({ launcher.launchCount == 3 }, "second backoff restart must launch")
        launcher.servers[2].exitNow(1) // fast exit 3 -> pause
        try await waitFor({ mgr.processes[0].state == .failed("crash loop — check log") },
                          "third fast exit must pause auto-restart")
        // A bulk start is a manual start: it resets the policy and relaunches.
        mgr.startAll(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 4)
        XCTAssertEqual(mgr.processes[0].state, .starting)
    }

    func testStartByIdStartsThatFolder() {
        let (mgr, launcher) = makeSUT()
        let id = mgr.processes[0].folder.id
        mgr.start(id: id, claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(mgr.processes[0].state, .starting)
        XCTAssertEqual(mgr.processes[1].state, .stopped)
    }

    func testStartByUnknownIdIsANoOp() {
        let (mgr, launcher) = makeSUT()
        mgr.start(id: UUID(), claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testSetFoldersReusesProcessAndUpdatesClaudePath() async throws {
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
        XCTAssertEqual(mgr.processes[0].claudePath, "/bin/true", "claudePath must propagate")
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

    func testSetFoldersSurvivesDuplicateIDs() {
        let (mgr, _) = makeSUT(folders: [validFolder()])
        let existing = mgr.processes[0].folder
        // A hand-edited config can repeat an id; this must not trap.
        mgr.setFolders([existing, existing], claudePath: nil)
        XCTAssertEqual(mgr.processes.count, 2)
        XCTAssertFalse(mgr.processes[0] === mgr.processes[1],
                       "the second copy gets its own process, not the reused one")
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

    // MARK: session entries

    /// Two existing folders with distinct names, both autostarting.
    private func twoNamedFolders() -> [FolderConfig] {
        var a = validFolder()
        a.name = "alpha"
        var b = validFolder()
        b.name = "beta"
        return [a, b]
    }

    func testSessionEntriesSkipFoldersWithoutSessions() async throws {
        let (mgr, launcher) = makeSUT(folders: twoNamedFolders())
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes.allSatisfy { $0.state == .running } }, "both must run")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ mgr.processes[0].sessionCount == 2 }, "count must arrive")
        XCTAssertEqual(mgr.activeSessionEntries, [SessionEntry(name: "alpha", count: 2)])
    }

    func testSessionEntriesKeepConfigOrder() async throws {
        let (mgr, launcher) = makeSUT(folders: twoNamedFolders())
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes.allSatisfy { $0.state == .running } }, "both must run")
        launcher.servers[1].onOutput?(Data("Capacity: 1/32".utf8))
        launcher.servers[0].onOutput?(Data("Capacity: 3/32".utf8))
        try await waitFor({ mgr.activeSessionEntries.count == 2 }, "both counts must arrive")
        XCTAssertEqual(mgr.activeSessionEntries,
                       [SessionEntry(name: "alpha", count: 3),
                        SessionEntry(name: "beta", count: 1)])
    }

    func testSessionEntriesOfASubset() async throws {
        let (mgr, launcher) = makeSUT(folders: twoNamedFolders())
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes.allSatisfy { $0.state == .running } }, "both must run")
        launcher.servers[1].onOutput?(Data("Capacity: 1/32".utf8))
        try await waitFor({ mgr.processes[1].sessionCount == 1 }, "count must arrive")
        XCTAssertEqual(ServerManager.sessionEntries(of: [mgr.processes[1]]),
                       [SessionEntry(name: "beta", count: 1)])
        XCTAssertEqual(ServerManager.sessionEntries(of: [mgr.processes[0]]), [])
    }
}
