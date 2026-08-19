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
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
