import Foundation

/// Wording for the active-session warning and the menu suffix. Pure, so the
/// plural split and the enumeration are testable without a modal.
enum SessionAlertText {
    /// What the user is about to do. Quit and Stop get different wording.
    enum Scope {
        case quit, stop

        var titleKey: String {
            self == .quit ? "alert.sessions.quit.title" : "alert.sessions.stop.title"
        }

        var confirmKey: String {
            self == .quit ? "alert.sessions.confirm.quit" : "alert.sessions.confirm.stop"
        }
    }

    /// The table holds plain strings, so singular and plural are two keys.
    /// The singular carries no argument.
    private static func counted(_ key: String, _ count: Int) -> String {
        // Int32 like the other numeric keys in this catalog (L10n.swift:39):
        // %d is a 32-bit conversion.
        count == 1 ? L10n.t(key + ".one") : L10n.t(key + ".other", Int32(count))
    }

    static func title(scope: Scope, count: Int) -> String {
        counted(scope.titleKey, count)
    }

    /// Names every affected folder with its own count.
    static func body(entries: [SessionEntry]) -> String {
        let list = entries.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
        return L10n.t("alert.sessions.body.list", list)
    }

    /// Title of the destructive button.
    static func confirmButton(scope: Scope) -> String { L10n.t(scope.confirmKey) }

    /// Sessions an action would end. SessionAlert asks whenever this is one
    /// or more.
    static func total(of entries: [SessionEntry]) -> Int {
        entries.reduce(0) { $0 + $1.count }
    }

    /// Suffix for a menu row, nil when there is nothing to show.
    static func menuSuffix(count: Int) -> String? {
        guard count >= 1 else { return nil }
        return counted("menu.sessions", count)
    }

    /// Extra sentence for the existing Remove confirmation, nil when the
    /// folder has no sessions.
    static func removeSentence(count: Int) -> String? {
        guard count >= 1 else { return nil }
        return counted("alert.remove.sessions", count)
    }
}
