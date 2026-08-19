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
        let total = SessionAlertText.total(of: entries)
        guard total >= 1 else { return true }
        let alert = NSAlert()
        alert.messageText = SessionAlertText.title(scope: scope, count: total)
        alert.informativeText = SessionAlertText.body(entries: enumerate ? entries : [])
        return alert.runDestructive(cancel: L10n.t("alert.sessions.cancel"),
                                    confirm: SessionAlertText.confirmButton(scope: scope))
    }
}

extension NSAlert {
    /// Runs a confirmation whose second button destroys something, and
    /// returns true when the user picked it.
    ///
    /// Cancel is added first, so the destructive button is never the one
    /// Return activates. AppKit binds Escape only to a button literally
    /// titled "Cancel", which six of the seven translations are not, so the
    /// key equivalent is set by hand; that also takes Return off this
    /// button, which leaves no key press that destroys anything.
    @MainActor
    func runDestructive(cancel: String, confirm: String) -> Bool {
        addButton(withTitle: cancel)
        addButton(withTitle: confirm)
        buttons[1].hasDestructiveAction = true
        buttons[0].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return runModal() == .alertSecondButtonReturn
    }
}
