import XCTest
@testable import ClaudeRCManager

/// Stand-in for a launched server. Pids are assigned by the launcher that
/// created it, so servers from one launcher have distinct pids — the
/// external-scan exclusion depends on that.
final class FakeServer: RunningServer {
    let scriptPid: pid_t
    let innerPid: pid_t?
    var pids: [pid_t] { [scriptPid, innerPid].compactMap { $0 } }
    var onExit: ((Int32) -> Void)?
    var onOutput: ((Data) -> Void)?
    var stopped = false
    var killed = false

    init(scriptPid: pid_t, innerPid: pid_t) {
        self.scriptPid = scriptPid
        self.innerPid = innerPid
    }

    func stop(gracePeriod: TimeInterval) { stopped = true }
    func kill() { killed = true }
    func exitNow(_ status: Int32) { onExit?(status) }
}

final class FakeLauncher: ProcessLaunching {
    var servers: [FakeServer] = []
    var launchCount = 0
    var error: Error?
    /// Every server gets its own script/inner pid pair.
    private var nextPid: pid_t = 111

    func launch(argv: [String], workingDirectory: String,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningServer
    {
        if let error { throw error }
        launchCount += 1
        let s = FakeServer(scriptPid: nextPid, innerPid: nextPid + 1)
        nextPid += 2
        s.onOutput = onOutput
        s.onExit = onExit
        servers.append(s)
        return s
    }
}

struct WaitTimeout: Error {}

extension XCTestCase {
    /// Polls instead of sleeping a fixed span: callbacks hop to the main actor
    /// and timers fire on their own schedule, so an assertion right after a
    /// fixed sleep is a race in both directions (too early, or so late that a
    /// transient state such as `.restarting` is already gone).
    ///
    /// Throws on timeout so the test stops instead of indexing into state that
    /// never materialized (a trap would kill the whole test binary).
    @MainActor
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
}
