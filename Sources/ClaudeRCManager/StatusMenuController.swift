import AppKit

// ConfigHealth is declared next to ConfigStore, derived from its LoadResult.

/// NSStatusItem + menu, rebuilt on every open via menuNeedsUpdate (spec:
/// Menu structure). Icon updates on every state change, independent of the
/// menu being open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let manager: ServerManager
    private let cli: ClaudeCLI
    private let store: ConfigStore
    private let settings = SettingsWindowController()
    private var config: AppConfig
    private let configHealth: ConfigHealth
    private var cachedLoggedIn = false
    private var externalServers: [ExternalServer] = []
    /// Menus can be opened faster than a scan completes; without this a
    /// held-open menu would pile up concurrent pgrep/lsof sweeps.
    private var isRefreshing = false
    /// The save-refused alert is per session, not per change: after an
    /// `.unreadable` load every single edit would otherwise raise it.
    private var didWarnAboutSaveFailure = false

    init(config: AppConfig, configHealth: ConfigHealth, manager: ServerManager,
         cli: ClaudeCLI, store: ConfigStore)
    {
        self.config = config
        self.configHealth = configHealth
        self.manager = manager
        self.cli = cli
        self.store = store
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        manager.onAnyStateChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    /// Called from main.swift once the launch-time resolution finishes, so
    /// the first menu open does not show stale "not logged in" state.
    func setLoggedIn(_ loggedIn: Bool) {
        cachedLoggedIn = loggedIn
        refreshIcon()
    }

    func refreshIcon() {
        let healthy = cachedLoggedIn && cli.binaryPath != nil && configHealth == .ok
        let bucket = StatusIcon.bucket(states: manager.states, healthy: healthy)
        let image = NSImage(systemSymbolName: bucket.symbolName,
                            accessibilityDescription: bucket.accessibilityDescription)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(bucket.accessibilityDescription)
    }

    /// Called from main.swift once the launch-time binary resolution
    /// finishes. Uses the live config, not the one captured at launch: the
    /// user can add or edit a folder while resolution is still running, and
    /// re-sending the launch-time list would stop and drop that folder.
    func applyResolvedPath(_ path: String?) {
        manager.setFolders(config.folders, claudePath: path)
    }

    /// Refreshes auth + external scan off the main thread; the results
    /// update the icon immediately and feed the NEXT menu open (an open
    /// NSMenu is not rebuilt mid-display).
    func refreshAuthAndExternal() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let ownPids = manager.ownPids()
        DispatchQueue.global().async { [weak self, cli] in
            _ = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            let external = ExternalServerScanner.scan(excluding: ownPids)
            DispatchQueue.main.async { [weak self] in
                self?.isRefreshing = false
                self?.cachedLoggedIn = loggedIn
                self?.externalServers = external
                self?.refreshIcon()
            }
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAuthAndExternal()
        menu.removeAllItems()

        // Cached values only — no blocking CLI calls on the main thread.
        if cli.binaryPath == nil {
            menu.addItem(disabled(L10n.t("warning.cliNotFound")))
            menu.addItem(.separator())
        } else if !cachedLoggedIn {
            menu.addItem(disabled(L10n.t("warning.notLoggedIn")))
            let login = NSMenuItem(title: L10n.t("menu.openLogin"),
                                   action: #selector(openLogin), keyEquivalent: "")
            login.target = self
            menu.addItem(login)
            menu.addItem(.separator())
        }
        switch configHealth {
        case .ok:
            break
        case .recoveredFromCorrupt:
            menu.addItem(disabled(L10n.t("warning.configCorrupt")))
            menu.addItem(.separator())
        case .unreadable:
            menu.addItem(disabled(L10n.t("warning.configUnreadable")))
            menu.addItem(.separator())
        }

        for process in manager.processes {
            menu.addItem(folderItem(for: process))
        }
        if !manager.processes.isEmpty { menu.addItem(.separator()) }

        if !externalServers.isEmpty {
            menu.addItem(disabled(L10n.t("external.header")))
            for server in externalServers {
                let name = (server.workingDirectory as NSString?)?.lastPathComponent
                    ?? L10n.t("external.pidFallback", String(server.pid))
                let item = disabled(L10n.t("external.row", name))
                item.toolTip = server.workingDirectory ?? server.command
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let add = NSMenuItem(title: L10n.t("menu.addFolder"), action: #selector(addFolder), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let startAll = NSMenuItem(title: L10n.t("menu.startAll"), action: #selector(startAllAction), keyEquivalent: "")
        startAll.target = self
        menu.addItem(startAll)
        let stopAll = NSMenuItem(title: L10n.t("menu.stopAll"), action: #selector(stopAllAction), keyEquivalent: "")
        stopAll.target = self
        menu.addItem(stopAll)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: L10n.t("menu.startAtLogin"),
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        if !LoginItem.isAvailable {
            loginItem.action = nil
            loginItem.toolTip = L10n.t("menu.startAtLogin.tooltip")
        }
        menu.addItem(loginItem)

        // Not wired to NSApplication.terminate(_:) — see quitApp(). Measured
        // on macOS 26: the standard selector makes AppKit draw an automatic
        // glyph, and macOS 26 indents only decorated items, so that single
        // glyph pushed both the Quit title and the checked "start at login"
        // title right while the undecorated items stayed put.
        let quit = NSMenuItem(title: L10n.t("menu.quit"),
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func statusLabel(_ state: ServerState) -> String {
        switch state {
        case .stopped: return L10n.t("status.stopped")
        case .starting: return L10n.t("status.starting")
        case .running: return L10n.t("status.running")
        case .stopping: return L10n.t("status.stopping")
        case .restarting: return L10n.t("status.restarting")
        case .ended: return L10n.t("status.ended")
        case .failed(let reason): return L10n.t("status.failed", L10n.displayReason(reason))
        }
    }

    /// State plus the session count, when the server reported one.
    private func rowLabel(for process: ServerProcess) -> String {
        let state = statusLabel(process.state)
        guard let suffix = SessionAlertText.menuSuffix(count: process.activeSessions) else {
            return state
        }
        return "\(state) \(suffix)"
    }

    private func folderItem(for process: ServerProcess) -> NSMenuItem {
        let folder = process.folder
        let item = NSMenuItem(
            title: "\(folder.name)   \(rowLabel(for: process))",
            action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let toggle = NSMenuItem(
            title: L10n.t(process.state.isActive ? "menu.stop" : "menu.start"),
            action: #selector(toggleServer(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = folder.id
        submenu.addItem(toggle)

        let log = NSMenuItem(title: L10n.t("menu.openLog"), action: #selector(openLog(_:)), keyEquivalent: "")
        log.target = self
        log.representedObject = folder.id
        submenu.addItem(log)

        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"),
                                      action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.representedObject = folder.id
        submenu.addItem(settingsItem)

        let remove = NSMenuItem(title: L10n.t("menu.remove"), action: #selector(removeFolder(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = folder.id
        submenu.addItem(remove)

        item.submenu = submenu
        return item
    }

    // MARK: Actions

    @objc private func openLogin() {
        DispatchQueue.global().async { [cli] in
            let opened = cli.openLoginInTerminal()
            guard !opened else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = L10n.t("alert.terminal.title")
                alert.informativeText = L10n.t("alert.terminal.body")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func toggleServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        if process.state.isActive {
            guard SessionAlert.confirm(
                scope: .stop,
                entries: ServerManager.sessionEntries(of: [process])) else { return }
            process.stop()
        } else {
            // Resolve + auth off the main thread, then start on main.
            DispatchQueue.global().async { [weak self, cli] in
                let path = cli.resolveBinary()
                let loggedIn = cli.isLoggedIn()
                DispatchQueue.main.async { [weak self] in
                    self?.cachedLoggedIn = loggedIn
                    self?.manager.start(id: id, claudePath: path, loggedIn: loggedIn)
                }
            }
        }
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        NSWorkspace.shared.open(process.logURL)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        settings.show(folder: process.folder) { [weak self] updated in
            self?.replaceFolder(updated)
        }
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.remove.title", process.folder.name)
        // The session sentence is added to this confirmation, so removing a
        // folder with live sessions still shows one dialog. A separate line
        // rather than a joined sentence: the two catalogs that write without
        // spaces after a full stop would otherwise carry a stray one.
        if let sessions = SessionAlertText.removeSentence(count: process.activeSessions) {
            alert.informativeText = sessions + "\n" + L10n.t("alert.remove.body")
        } else {
            alert.informativeText = L10n.t("alert.remove.body")
        }
        guard alert.runDestructive(cancel: L10n.t("alert.remove.cancel"),
                                   confirm: L10n.t("alert.remove.confirm")) else { return }
        process.stop()
        // An open settings window for this folder still holds the folder
        // snapshot it opened with; its Save would resurrect the removed
        // folder in the config.
        settings.close(id: id)
        config.folders.removeAll { $0.id == id }
        persist()
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        // String comparison would miss the same folder reached through a
        // symlink, a trailing slash, or /tmp vs /private/tmp — and two
        // processes on one directory is exactly what this check exists for.
        let canonical = Self.canonicalPath(path)
        guard !config.folders.contains(where: { Self.canonicalPath($0.path) == canonical }) else {
            let alert = NSAlert()
            alert.messageText = L10n.t("alert.duplicateFolder.title")
            alert.informativeText = path
            alert.runModal()
            return
        }
        let folder = FolderConfig(path: path)
        config.folders.append(folder)
        persist()
        settings.show(folder: folder) { [weak self] updated in
            self?.replaceFolder(updated)
        }
    }

    @objc private func startAllAction() {
        DispatchQueue.global().async { [weak self, cli] in
            let path = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            DispatchQueue.main.async { [weak self] in
                self?.cachedLoggedIn = loggedIn
                self?.manager.startAll(claudePath: path, loggedIn: loggedIn)
            }
        }
    }

    @objc private func stopAllAction() {
        guard SessionAlert.confirm(scope: .stop, entries: manager.activeSessionEntries)
        else { return }
        manager.stopAll()
    }

    /// Quit goes through our own selector rather than the standard
    /// `terminate:` action so macOS 26 does not decorate the item with an
    /// automatic glyph; the termination path (and applicationShouldTerminate)
    /// is otherwise identical, and ⌘Q still works from the open menu.
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func toggleLoginItem() {
        if let message = LoginItem.toggle() {
            let alert = NSAlert()
            alert.messageText = L10n.t("alert.loginItem.title")
            alert.informativeText = message
            alert.runModal()
        }
    }

    private func replaceFolder(_ updated: FolderConfig) {
        guard let index = config.folders.firstIndex(where: { $0.id == updated.id }) else { return }
        config.folders[index] = updated
        persist()
    }

    /// The in-memory config is the source of truth for the running app, so a
    /// failed save still applies to the manager — but it must not fail
    /// silently: after an `.unreadable` load ConfigStore refuses to save at
    /// all, and the user would otherwise lose every change at quit without
    /// ever being told.
    private func persist() {
        // The manager is updated first, unconditionally: the modal alert
        // below spins the run loop, and the running app must already agree
        // with the in-memory config before the user is talking to a dialog.
        manager.setFolders(config.folders, claudePath: cli.binaryPath)
        do {
            try store.save(config)
        } catch {
            guard !didWarnAboutSaveFailure else { return }
            didWarnAboutSaveFailure = true
            let alert = NSAlert()
            alert.messageText = L10n.t("alert.saveFailed.title")
            alert.informativeText = configHealth == .unreadable
                ? L10n.t("alert.saveFailed.unreadable")
                : L10n.t("alert.saveFailed.body", error.localizedDescription)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
