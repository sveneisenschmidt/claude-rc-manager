import Foundation

enum ServerState: Equatable {
    case stopped, starting, running, stopping, restarting, ended
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running, .stopping, .restarting: return true
        default: return false
        }
    }

    /// States a (bulk) start may act on.
    var canStart: Bool {
        switch self {
        case .stopped, .ended, .failed: return true
        default: return false
        }
    }
}

/// State machine for one folder's server (spec: States, Crash handling).
/// Main-thread confined: the exit callback hops to the main actor before it
/// touches anything here. The output callback deliberately does NOT — it runs
/// on the pty reader thread and hands the bytes to its LogWriter and its
/// SessionCounter, both internally locked, so no state of this class is read
/// off the main actor.
@MainActor
final class ServerProcess {
    private(set) var folder: FolderConfig
    private(set) var state: ServerState = .stopped {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: ((ServerState) -> Void)?

    private let launcher: ProcessLaunching
    private let logDirectory: URL
    /// Settable: the real path resolves asynchronously after app launch.
    var claudePath: String
    /// Re-checked before every start, including auto-restarts (spec: Start
    /// preconditions). Returns a failure reason or nil. Set by ServerManager.
    var preflight: (() -> String?)?
    private let readinessDelay: TimeInterval
    private let backoffScale: Double
    private var server: RunningServer?
    private var logWriter: LogWriter?
    private var policy = RestartPolicy()
    /// Monotonic: the run duration feeds the restart policy, and a wall-clock
    /// jump must not make a crash loop look like a stable run.
    private var startedAt: DispatchTime?
    private var restartTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var userStopRequested = false

    var logURL: URL {
        logDirectory.appendingPathComponent("\(folder.id.uuidString).log")
    }

    init(folder: FolderConfig, launcher: ProcessLaunching, logDirectory: URL,
         claudePath: String, readinessDelay: TimeInterval = 5,
         backoffScale: Double = 1)
    {
        self.folder = folder
        self.launcher = launcher
        self.logDirectory = logDirectory
        self.claudePath = claudePath
        self.readinessDelay = readinessDelay
        self.backoffScale = backoffScale
    }

    func update(folder: FolderConfig) {
        // Settings apply on next start (spec: SettingsWindow). A running
        // server keeps the snapshot it launched with (`launchedFolder`), so
        // an edit cannot change how the current run's exit is handled.
        self.folder = folder
    }

    /// The folder configuration the current run was launched with.
    private var launchedFolder: FolderConfig?

    /// Last count the running server reported, nil while unknown. Cleared
    /// when a run ends, which is the only place it needs clearing: a new run
    /// can only start once the previous one is over. Read by the tests;
    /// callers use `activeSessions`.
    private(set) var sessionCount: Int?
    /// One counter per run: a chunk can still be in flight when a run ends,
    /// and its report must not survive into the next one.
    private var counter: SessionCounter?

    func start(manual: Bool) {
        // `.restarting` counts as active (the server is still "on"), but the
        // scheduled auto-restart starts out of exactly that state, as does a
        // manual start that cuts the backoff wait short.
        guard !state.isActive || state == .restarting else { return }
        // Drop timers from the previous run: a pending backoff timer would
        // fire a second launch, a stale readiness task would mark this run
        // .running on the old run's schedule.
        restartTask?.cancel()
        restartTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        if manual { policy.reset() }
        userStopRequested = false
        if let reason = preflight?() {
            state = .failed(reason) // precondition failures skip policy accounting
            return
        }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            state = .failed("folder missing")
            return
        }
        do {
            // Close any previous writer first: rotation renames the file, and
            // a live handle would keep writing into the rotated inode.
            logWriter?.close()
            logWriter = try? LogWriter(url: logURL)
            // Captured by value: the pty thread must not reach through self
            // for the writer. LogWriter serializes its own writes.
            let writer = logWriter
            let argv = CommandBuilder.argv(for: folder, claudePath: claudePath)
            let counter = SessionCounter()
            self.counter = counter
            // [weak counter]: the counter owns this closure, so a strong
            // capture would keep one counter per run alive for the app's life.
            counter.onChange = { [weak self, weak counter] value in
                Task { @MainActor [weak self, weak counter] in
                    guard let counter else { return }
                    self?.apply(count: value, from: counter)
                }
            }
            let server = try launcher.launch(
                argv: argv, workingDirectory: folder.path,
                onOutput: { [writer, counter] data in
                    writer?.append(data)
                    counter.feed(data)
                },
                onExit: { [weak self] status in
                    // Inner capture list copies the weak binding: older
                    // compilers (CI's macos-14 Swift) reject referencing the
                    // outer mutable weak var from a concurrent closure.
                    Task { @MainActor [weak self] in self?.handleExit(status: status) }
                })
            self.server = server
            launchedFolder = folder
            startedAt = DispatchTime.now()
            state = .starting
            readinessTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.readinessDelay ?? 5) * 1e9))
                guard !Task.isCancelled else { return }
                if self?.state == .starting { self?.state = .running }
            }
        } catch {
            // Nothing will ever write to this run's log: release the handle.
            logWriter?.close()
            logWriter = nil
            state = .failed("launch error")
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        if state == .restarting {
            state = .stopped
            return
        }
        guard state.isActive, let server else { return }
        userStopRequested = true
        state = .stopping
        server.stop(gracePeriod: 5)
    }

    func killNow() {
        restartTask?.cancel()
        restartTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        // A kill is a deliberate stop: the exit it triggers must not be
        // mistaken for a crash and scheduled for restart.
        userStopRequested = true
        server?.kill()
    }

    /// Ignores a report from a superseded run.
    private func apply(count: Int, from source: SessionCounter) {
        guard source === counter else { return }
        sessionCount = count
    }

    private func handleExit(status: Int32) {
        server = nil
        sessionCount = nil
        counter = nil
        // This run is over: its readiness timer must not promote a later run.
        readinessTask?.cancel()
        readinessTask = nil
        let runDuration = startedAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e9
        } ?? 0
        // Flush and release the log handle: the next start rotates the file.
        logWriter?.close()
        logWriter = nil
        // Decide from the snapshot this run launched with: a settings edit
        // during the run must not change how this exit is handled.
        let ranAs = launchedFolder ?? folder
        launchedFolder = nil
        if userStopRequested {
            state = .stopped
            return
        }
        if ranAs.spawnMode == .session {
            state = .ended // the CLI exits when the session ends: expected
            return
        }
        guard ranAs.autoRestart else {
            state = .failed("exited, status \(status)")
            return
        }
        switch policy.recordExit(runDuration: runDuration) {
        case .crashLoopPause:
            state = .failed("crash loop — check log")
        case .restart(let delay):
            state = .restarting
            let scaled = delay * backoffScale
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(scaled * 1e9))
                guard let self, self.state == .restarting else { return }
                self.start(manual: false)
            }
        }
    }

    /// Sessions this server is running, for the menu row and the warning
    /// shown before a stop.
    ///
    /// `.stopping` reports none: the server is already on its way down, so
    /// asking about its sessions again can no longer save them.
    var activeSessions: Int {
        // The run's own snapshot, the same rule handleExit follows: a settings
        // edit mid-run must not change how this run is counted. No snapshot
        // means no live run (waiting out a restart backoff), hence no sessions.
        guard state.isActive, state != .stopping,
              let ranAs = launchedFolder else { return 0 }
        // Session mode prints no capacity line: the server is the session.
        if ranAs.spawnMode == .session { return 1 }
        return sessionCount ?? 0
    }

    // Used by ServerManager and the external-scan exclusion.
    var pids: [pid_t] { server?.pids ?? [] }
    var innerPid: pid_t? { server?.innerPid }

    func setPreconditionFailure(_ reason: String) {
        guard !state.isActive else { return }
        state = .failed(reason)
    }
}
