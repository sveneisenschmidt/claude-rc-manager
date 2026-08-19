import Foundation
import ServiceManagement

/// Start-at-login via SMAppService (spec: Menu structure). Registration
/// binds to the recorded bundle path, so it only makes sense from
/// /Applications; the menu disables the checkbox elsewhere.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Returns an error message for an alert, or nil on success.
    static func toggle() -> String? {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                // register() succeeds but stays inert until the user approves
                // it; without this the checkbox would silently do nothing.
                if SMAppService.mainApp.status == .requiresApproval {
                    return "Approve Claude RC Manager in System Settings > General > Login Items."
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
