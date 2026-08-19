import Foundation

/// Localization lookup. The installed .app carries the .lproj set in its
/// main bundle (copied by `make app`) — and the main bundle is also what
/// macOS uses for language negotiation. Bare `swift run`/`swift test`
/// have no localized main bundle; they fall back to the SwiftPM resource
/// bundle. Never call `Bundle.module` when the main bundle carries the
/// strings: in the installed app the module accessor would fatalError.
enum L10n {
    static let bundle: Bundle = {
        if Bundle.main.path(forResource: "Localizable", ofType: "strings",
                            inDirectory: nil, forLocalization: "en") != nil {
            return .main
        }
        return .module
    }()

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }

    /// Failure reasons are English identifiers internally (spec). Map the
    /// five fixed reasons exactly, the parameterized exited-status shape
    /// by prefix, and render anything unrecognized as its raw text.
    static func displayReason(_ reason: String) -> String {
        switch reason {
        case "claude not found": return t("reason.claudeNotFound")
        case "not logged in": return t("reason.notLoggedIn")
        case "folder missing": return t("reason.folderMissing")
        case "crash loop — check log": return t("reason.crashLoop")
        case "launch error": return t("reason.launchError")
        default:
            let prefix = "exited, status "
            if reason.hasPrefix(prefix), let n = Int32(reason.dropFirst(prefix.count)) {
                return t("reason.exited", n)
            }
            return reason
        }
    }
}
