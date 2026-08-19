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
/// Main-thread confined; all callbacks hop to the main queue.
@MainActor
final class ServerProcess {
    private(set) var folder: FolderConfig
    private(set) var state: ServerState = .stopped {
        didSet { onStateChange?(state) }
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
        // Settings apply on next start (spec: SettingsWindow).
        self.folder = folder
    }

    func start(manual: Bool) {
        // `.restarting` counts as active (the server is still "on"), but the
        // scheduled auto-restart starts out of exactly that state, as does a
        // manual start that cuts the backoff wait short.
        guard !state.isActive || state == .restarting else { return }
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
            let argv = CommandBuilder.argv(for: folder, claudePath: claudePath)
            let server = try launcher.launch(argv: argv, workingDirectory: folder.path)
            self.server = server
            startedAt = DispatchTime.now()
            state = .starting
            server.onOutput = { [weak self] data in
                self?.logWriter?.append(data)
            }
            server.onExit = { [weak self] status in
                Task { @MainActor in self?.handleExit(status: status) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.readinessDelay ?? 5) * 1e9))
                if self?.state == .starting { self?.state = .running }
            }
        } catch {
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
        server?.kill()
    }

    private func handleExit(status: Int32) {
        server = nil
        let runDuration = startedAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e9
        } ?? 0
        // Flush and release the log handle: the next start rotates the file.
        logWriter?.close()
        logWriter = nil
        if userStopRequested {
            state = .stopped
            return
        }
        if folder.spawnMode == .session {
            state = .ended // the CLI exits when the session ends: expected
            return
        }
        guard folder.autoRestart else {
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

    // Used by ServerManager and the external-scan exclusion.
    var pids: [pid_t] { server?.pids ?? [] }
    var innerPid: pid_t? { server?.innerPid }

    func setPreconditionFailure(_ reason: String) {
        guard !state.isActive else { return }
        state = .failed(reason)
    }
}
