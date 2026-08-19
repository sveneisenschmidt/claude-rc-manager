import AppKit

// NOT @MainActor on the class: top-level code in main.swift is nonisolated,
// so a @MainActor init would not compile (verified by probe). The
// NSApplicationDelegate callbacks are main-actor anyway.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: StatusMenuController?
    var manager: ServerManager?
    let cli = ClaudeCLI()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance (spec: Process lifecycle). Bundle id exists only
        // in the .app bundle; skip the check for bare-binary dev runs.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1
        {
            NSApp.terminate(nil)
            return
        }

        let store = ConfigStore()
        let config: AppConfig
        let health: ConfigHealth
        switch store.load() {
        case .loaded(let c): config = c; health = .ok
        case .recoveredFromCorrupt(let c): config = c; health = .recoveredFromCorrupt
        case .unreadable(let c): config = c; health = .unreadable
        }

        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClaudeRCManager")
        let manager = ServerManager(
            config: config, launcher: ScriptLauncher(), logDirectory: logDir)
        self.manager = manager
        // Preflight re-checks preconditions on every start, restarts
        // included. isLoggedIn() is cached for 60 s.
        manager.preflight = { [cli] in
            guard cli.binaryPath != nil else { return "claude not found" }
            return cli.isLoggedIn() ? nil : "not logged in"
        }
        menuController = StatusMenuController(
            config: config, configHealth: health,
            manager: manager, cli: cli, store: store)

        DispatchQueue.global().async { [cli] in
            let path = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            DispatchQueue.main.async { [weak self] in
                self?.menuController?.setLoggedIn(loggedIn)
                self?.manager?.setFolders(config.folders, claudePath: path)
                self?.manager?.autostart(claudePath: path, loggedIn: loggedIn)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager, manager.anyActive else { return .terminateNow }
        manager.stopAll()
        // Shared 5 s deadline, then SIGKILL stragglers (spec: quit).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            manager.killAllNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

if NSClassFromString("XCTestCase") == nil {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
