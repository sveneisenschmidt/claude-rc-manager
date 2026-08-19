import AppKit
import CoreServices

// NOT @MainActor on the class: top-level code in main.swift is nonisolated,
// so a @MainActor init would not compile (verified by test compile). The
// NSApplicationDelegate callbacks are main-actor anyway.
// Revisit on a Swift 6 language-mode migration: the isolation of this class
// (and of the top-level code below) is the one thing here that will need a
// different shape, e.g. @main + an explicitly isolated entry point.
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
        let loaded = store.load()
        let config = loaded.config
        let health = loaded.health

        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClaudeRCManager")
        let manager = ServerManager(
            config: config, launcher: PtyLauncher(), logDirectory: logDir)
        self.manager = manager
        // Preflight re-checks preconditions on every start, auto-restarts
        // included — and it runs on the main actor, so it must never call
        // the blocking isLoggedIn() (a cold cache busy-polls `claude auth
        // status` for up to 5 s, freezing the UI on every restart).
        //
        // Only the non-blocking cached verdict is read. A cold or expired
        // cache is treated as logged in for this one attempt and a refresh
        // is kicked off: an actually-logged-out server fails visibly within
        // seconds anyway (the CLI exits and the menu shows the failure),
        // and by the next restart attempt the cache is warm and the
        // "not logged in" reason is accurate.
        manager.preflight = { [cli] in
            guard cli.binaryPath != nil else { return "claude not found" }
            switch cli.cachedLoggedIn {
            case .some(true):
                return nil
            case .some(false):
                cli.refreshAuthInBackground()
                return "not logged in"
            case .none:
                cli.refreshAuthInBackground()
                return nil
            }
        }
        menuController = StatusMenuController(
            config: config, configHealth: health,
            manager: manager, cli: cli, store: store)

        DispatchQueue.global().async { [cli] in
            let path = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            DispatchQueue.main.async { [weak self] in
                self?.menuController?.setLoggedIn(loggedIn)
                // Through the menu controller, which owns the live config:
                // resolution can take 15 s, and a folder added meanwhile
                // must not be stopped and dropped by a stale folder list.
                self?.menuController?.applyResolvedPath(path)
                self?.manager?.autostart(claudePath: path, loggedIn: loggedIn)
            }
        }
    }

    /// Keeps `reply(toApplicationShouldTerminate:)` to a single call: the poll
    /// and the deadline race each other, and replying twice is a hard AppKit
    /// error. Main-thread only, like both writers.
    private var didReplyToTerminate = false

    /// True when macOS is quitting the app as part of a logout, restart or
    /// shutdown. Cancelling there would cancel the user's logout, and the
    /// sessions end with the login session either way, so those never ask.
    ///
    /// Read from the event that triggered the quit rather than from
    /// NSWorkspace.willPowerOffNotification: that notification is delivered
    /// through the main queue and can arrive after this method has run.
    private var isSystemInitiatedQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        switch reason.enumCodeValue {
        case UInt32(kAELogOut), UInt32(kAEReallyLogOut),
             UInt32(kAEShowRestartDialog), UInt32(kAERestart),
             UInt32(kAEShowShutdownDialog), UInt32(kAEShutDown):
            return true
        default:
            return false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager, manager.anyActive else { return .terminateNow }
        // Nothing has been signalled yet, so cancelling here is complete.
        if !isSystemInitiatedQuit,
           !SessionAlert.confirm(scope: .quit, entries: manager.activeSessionEntries)
        {
            return .terminateCancel
        }
        manager.stopAll()

        func reply() {
            guard !didReplyToTerminate else { return }
            didReplyToTerminate = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        // Quit as soon as the last server is actually down; most stop in
        // well under a second, and sitting on a fixed 5.5 s delay makes the
        // app look hung at every quit.
        func poll() {
            guard !didReplyToTerminate else { return }
            if !manager.anyActive { reply(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
        }
        poll()
        // Shared 5 s deadline, then SIGKILL stragglers (spec: quit).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            guard !self.didReplyToTerminate else { return }
            manager.killAllNow()
            reply()
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
