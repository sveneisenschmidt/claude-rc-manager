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
    /// Re-checked before every start, auto-restarts included; wired to
    /// ClaudeCLI in main.swift. Returns a failure reason or nil.
    var preflight: (() -> String?)?

    init(config: AppConfig, launcher: ProcessLaunching, logDirectory: URL,
         readinessDelay: TimeInterval = 5)
    {
        self.launcher = launcher
        self.logDirectory = logDirectory
        self.readinessDelay = readinessDelay
        setFolders(config.folders, claudePath: nil)
    }

    func setFolders(_ folders: [FolderConfig], claudePath: String?) {
        var existing = Dictionary(uniqueKeysWithValues: processes.map { ($0.folder.id, $0) })
        processes = folders.map { folder in
            if let p = existing.removeValue(forKey: folder.id) {
                p.update(folder: folder)
                if let claudePath { p.claudePath = claudePath }
                return p
            }
            let p = ServerProcess(
                folder: folder, launcher: launcher, logDirectory: logDirectory,
                claudePath: claudePath ?? "claude", readinessDelay: readinessDelay)
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
        for p in processes where p.folder.autostart {
            start(p, claudePath: claudePath, loggedIn: loggedIn, manual: true)
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
