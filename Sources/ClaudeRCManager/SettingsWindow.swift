import AppKit
import SwiftUI

struct FolderSettingsView: View {
    @State var folder: FolderConfig
    let onSave: (FolderConfig) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            TextField(L10n.t("settings.name"), text: $folder.name)
            LabeledContent(L10n.t("settings.path")) {
                Text(folder.path).truncationMode(.middle).lineLimit(1)
            }
            Picker(L10n.t("settings.spawnMode"), selection: $folder.spawnMode) {
                ForEach(SpawnMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            Toggle(L10n.t("settings.createSessionInDir"), isOn: $folder.createSessionInDir)
            Stepper(L10n.t("settings.capacity", Int32(folder.capacity)), value: $folder.capacity, in: 1...128)
                .disabled(folder.spawnMode == .session) // spec: disabled, not hidden
            Picker(L10n.t("settings.permissionMode"), selection: $folder.permissionMode) {
                Text(L10n.t("settings.permissionMode.cliDefault")).tag(PermissionMode?.none)
                ForEach(PermissionMode.allCases, id: \.self) {
                    Text($0.rawValue).tag(PermissionMode?.some($0))
                }
            }
            TextField(L10n.t("settings.extraArgs"), text: $folder.extraArgs)
            Toggle(L10n.t("settings.autostart"), isOn: $folder.autostart)
            if folder.spawnMode != .session {
                Toggle(L10n.t("settings.autoRestart"), isOn: $folder.autoRestart)
            }
            Text(L10n.t("settings.applyHint"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.save")) { onSave(folder) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// One settings window per folder id at a time.
///
/// The dictionary must be evicted when the user closes a window with the red
/// button too: a retained window keeps the `@State` snapshot it was opened
/// with, and reopening it would show stale settings whose Save overwrites
/// newer config.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSWindow] = [:]

    func show(folder: FolderConfig, onSave: @escaping (FolderConfig) -> Void) {
        if let existing = windows[folder.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: FolderSettingsView(
                folder: folder,
                onSave: { [weak self] updated in
                    onSave(updated)
                    self?.close(id: folder.id)
                },
                onCancel: { [weak self] in self?.close(id: folder.id) })))
        window.title = L10n.t("settings.title", folder.name)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        windows[folder.id] = window
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Also called by the menu when a folder is removed.
    func close(id: UUID) {
        windows.removeValue(forKey: id)?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // By identity, not by id lookup: this delegate serves every window it
        // opened, and the notification is the only handle we get.
        windows = windows.filter { $0.value !== window }
    }
}
