import AppKit
import SwiftUI

struct FolderSettingsView: View {
    @State var folder: FolderConfig
    let onSave: (FolderConfig) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $folder.name)
            LabeledContent("Path") {
                Text(folder.path).truncationMode(.middle).lineLimit(1)
            }
            Picker("Spawn mode", selection: $folder.spawnMode) {
                ForEach(SpawnMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            Toggle("Pre-create session in directory", isOn: $folder.createSessionInDir)
            Stepper("Capacity: \(folder.capacity)", value: $folder.capacity, in: 1...128)
                .disabled(folder.spawnMode == .session) // spec: disabled, not hidden
            Picker("Permission mode", selection: $folder.permissionMode) {
                Text("CLI default").tag(PermissionMode?.none)
                ForEach(PermissionMode.allCases, id: \.self) {
                    Text($0.rawValue).tag(PermissionMode?.some($0))
                }
            }
            TextField("Extra arguments", text: $folder.extraArgs)
            Toggle("Start automatically", isOn: $folder.autostart)
            if folder.spawnMode != .session {
                Toggle("Restart on crash", isOn: $folder.autoRestart)
            }
            Text("Changes apply the next time the server starts.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(folder) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// One settings window per folder id at a time.
@MainActor
final class SettingsWindowController {
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
        window.title = "\(folder.name) — Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        windows[folder.id] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close(id: UUID) {
        windows.removeValue(forKey: id)?.close()
    }
}
