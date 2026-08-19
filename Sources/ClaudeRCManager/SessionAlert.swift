import AppKit

/// The confirmation shown before an action ends running sessions. Holds no
/// logic beyond assembling the modal: the wording is SessionAlertText, the
/// counts are ServerManager.
@MainActor
enum SessionAlert {
    /// True when the caller may proceed. Returns true without asking when
    /// nothing would be lost.
    ///
    /// `enumerate` false leaves the folder list out, for the single-folder
    /// Stop where the folder is already named by the menu.
    static func confirm(scope: SessionAlertText.Scope,
                        entries: [SessionEntry],
                        enumerate: Bool = true) -> Bool
    {
        guard SessionAlertText.needsWarning(entries: entries) else { return true }
        let total = SessionAlertText.total(of: entries)
        let alert = NSAlert()
        alert.messageText = SessionAlertText.title(scope: scope, count: total)
        alert.informativeText = SessionAlertText.body(entries: enumerate ? entries : [])
        // Cancel first, so the destructive button is never the default.
        alert.addButton(withTitle: L10n.t("alert.sessions.cancel"))
        alert.addButton(withTitle: SessionAlertText.confirm(scope: scope))
        alert.buttons[1].hasDestructiveAction = true
        // AppKit wires Escape only to a button literally titled "Cancel",
        // which six of the seven translations are not. Taking the key
        // equivalent for Escape also removes Return from this button, so no
        // key press confirms and Escape cancels in every language.
        alert.buttons[0].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
