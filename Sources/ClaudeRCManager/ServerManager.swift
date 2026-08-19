import Foundation

/// Owns all ServerProcess instances (spec: ServerManager). Autostart on
/// launch, bulk start/stop, quit coordination, pid bookkeeping for the
/// external-server scan.
@MainActor
final class ServerManager {
    private(set) var processes: [ServerProcess] = []
    var onAnyStateChange: (() -> Void)?

    private let launcher: ProcessLaunching
    private let logDirectory: URL
    private let readinessDelay: TimeInterval
    /// Shrinks the restart backoff in tests; 1 in production.
    private let backoffScale: Double
    /// Re-checked before every start, auto-restarts included; wired to
    /// ClaudeCLI in main.swift. Returns a failure reason or nil.
    var preflight: (() -> String?)?

    init(config: AppConfig, launcher: ProcessLaunching, logDirectory: URL,
         readinessDelay: TimeInterval = 5, backoffScale: Double = 1)
    {
        self.launcher = launcher
        self.logDirectory = logDirectory
        self.readinessDelay = readinessDelay
        self.backoffScale = backoffScale
        setFolders(config.folders, claudePath: nil)
    }

    func setFolders(_ folders: [FolderConfig], claudePath: String?) {
        // uniquingKeysWith, not uniqueKeysWithValues: a hand-edited config.json
        // can repeat a folder id, and a trap here would take the app down.
        // ConfigStore re-keys duplicates on load; this repeats the check for
        // suspenders. First wins, matching the load-time keep-the-first rule.
        var existing = Dictionary(
            processes.map { ($0.folder.id, $0) }, uniquingKeysWith: { first, _ in first })
        processes = folders.map { folder in
            if let p = existing.removeValue(forKey: folder.id) {
                p.update(folder: folder)
                if let claudePath { p.claudePath = claudePath }
                return p
            }
            let p = ServerProcess(
                folder: folder, launcher: launcher, logDirectory: logDirectory,
                claudePath: claudePath ?? "claude", readinessDelay: readinessDelay,
                backoffScale: backoffScale)
            p.onStateChange = { [weak self] _ in self?.onAnyStateChange?() }
            // Indirect on purpose: the manager's preflight is wired after the
            // processes exist, and may be replaced later.
            p.preflight = { [weak self] in self?.preflight?() }
            return p
        }
        // Removed folders: stop their servers.
        existing.values.forEach { $0.stop() }
    }

    func process(id: UUID) -> ServerProcess? {
        processes.first { $0.folder.id == id }
    }

    func start(id: UUID, claudePath: String?, loggedIn: Bool) {
        guard let p = process(id: id) else { return }
        start(p, claudePath: claudePath, loggedIn: loggedIn, manual: true)
    }

    private func start(_ p: ServerProcess, claudePath: String?, loggedIn: Bool, manual: Bool) {
        guard let claudePath else { p.setPreconditionFailure("claude not found"); return }
        guard loggedIn else { p.setPreconditionFailure("not logged in"); return }
        p.claudePath = claudePath
        p.start(manual: manual)
    }

    func autostart(claudePath: String?, loggedIn: Bool) {
        // manual: false — app launch is not a user "start this now", so it must
        // not reset the restart policy and clear a crash-loop pause. (At launch
        // every policy is fresh anyway; this matters after a config reload.)
        for p in processes where p.folder.autostart {
            start(p, claudePath: claudePath, loggedIn: loggedIn, manual: false)
        }
    }

    func startAll(claudePath: String?, loggedIn: Bool) {
        for p in processes where p.state.canStart {
            start(p, claudePath: claudePath, loggedIn: loggedIn, manual: true)
        }
    }

    func stopAll() {
        processes.forEach { $0.stop() }
    }

    /// Script + inner pids of managed servers, for the external-scan
    /// exclusion (the script command line matches the scan pattern too).
    func ownPids() -> Set<pid_t> {
        Set(processes.flatMap { $0.pids })
    }

    var states: [ServerState] { processes.map(\.state) }
    var anyActive: Bool { states.contains(where: \.isActive) }

    func killAllNow() {
        processes.forEach { $0.killNow() }
    }
}
