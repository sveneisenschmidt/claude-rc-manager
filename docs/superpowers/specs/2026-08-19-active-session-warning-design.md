# Active-session warning before a server is stopped

Issue #1. Status: design agreed 2026-08-19.

## Problem

Every path that stops a managed server kills whatever phone sessions run
inside it. `applicationShouldTerminate` calls `stopAll()` (`main.swift:83`)
and SIGKILLs anything still alive 5.5 s later (`main.swift:100`, `:102`);
each stop is SIGTERM to the process group followed by SIGKILL after a 5 s
grace period (`ServerProcess.swift:148`, `ProcessLauncher.swift:230-239`).
"Stop" for one folder (`StatusMenuController.swift:239`), "Stop All"
(`ServerManager.swift:88`, reached from `StatusMenuController.swift:328`)
and "Remove" (`StatusMenuController.swift:271`) do the same for their
subset. `ServerManager.setFolders` also stops dropped folders
(`ServerManager.swift:54`), but today only Remove reaches it, so it is not a
separate call site.

The app cannot warn about the loss because it does not know a session
exists: it tracks the server process, and the pty stream it reads goes
straight to the log writer without being inspected (`ServerProcess.swift:114`).

## Source of the count

The CLI prints its own session count on every redraw:

```
·✔︎· Connected · claude-rc-manager
    Capacity: 1/32 · New sessions will be created in an isolated worktree
    Attached
```

`N` in `Capacity: N/M` is the size of the CLI's live-session map, verified in
the CLI binary (claude 2.1.227) and against the four server logs present in
`~/Library/Logs/ClaudeRCManager/` on 2026-08-19, all of them worktree-mode
runs. It is the server's own account of its sessions and arrives on a stream
the app already reads.

The two alternatives were rejected: counting child processes of the inner pid
infers what the CLI states outright, and re-reading the log file at quit time
reads back what the app is writing and can be stale by a whole redraw.

## Decisions

1. The count comes from the pty stream, not from process inspection.
2. All four call sites warn, not just quit.
3. An unknown count means "no sessions"; spawn mode `session` counts as one.
4. The alert names the affected folders and their counts.
5. The menu row shows the count too.
6. A pre-created standby session counts like any other (see Limitations).
7. Logout and restart do not ask (see Call sites).

## Components

### SessionCounter (new)

Receives the same pty chunks as the `LogWriter`, extracts the count from
`Capacity: <N>/<M>`, and reports it when it changes.

- Runs on the pty reader thread with its mutable state behind a lock, the
  same arrangement `LogWriter` uses (`LogWriter.swift:14`).
- Escape sequences are removed with `LogWriter.filter`
  (`LogWriter.swift:32`) before matching.
- The last match in a chunk wins: one read can carry several redraws.
- The trailing 256 bytes of each chunk are carried over to the next one, so
  a match split across two reads is still found. Older bytes are dropped.

### ServerProcess

- `sessionCount: Int?`: `nil` means unknown. Set from the counter, hopping
  to the main actor like the exit callback (`ServerProcess.swift:119`).
  Reset to `nil` at the start of every run and when the process exits.
- One counter per run. A report is applied only if it comes from the run's
  current counter (identity check), so a report already in flight when a run
  ends cannot land after the reset.
- `activeSessions: Int`, the single value every caller uses:
  - state not active → `0`
  - spawn mode `session` and state active → `1`. In that mode the CLI exits
    when the session ends (`ServerProcess.swift:181`; design doc
    `2026-08-19-claude-rc-manager-design.md:234-235`) and prints no capacity
    line — it rejects `--capacity` outright, which `CommandBuilder.swift:14-16`
    already accounts for. The mode is read from the snapshot the run was
    launched with, the same value `handleExit` uses
    (`ServerProcess.swift:175`), so a settings edit during a run cannot
    change how this run is counted.
  - otherwise → `sessionCount ?? 0`. Unknown counts as none: a server that
    has not reported yet is seconds old, and warning there would put the
    dialog in front of most quits until people click it away unread.
- No push refresh is needed when the count changes: the menu is rebuilt on
  open (`menuNeedsUpdate`), and the status icon buckets
  (`StatusMenuController.swift:40` → `refreshIcon()`) do not depend on the
  count.

### ServerManager

```swift
/// Folder name and session count, for folders that have at least one.
/// Order follows `processes`, which is config order (`setFolders`).
func sessionEntries(of processes: [ServerProcess]) -> [(name: String, count: Int)]
var totalActiveSessions: Int   // sum over all processes
```

`sessionEntries` filters on `activeSessions >= 1`; a server that is active
with an unknown count is not included, per decision 3.

### Alert

Split in two so the wording can be tested:

- `SessionAlertText`, pure functions: `title(scope:count:)` for scope
  `.quit` / `.stop`, `body(entries:)` (empty list yields the variant without
  the enumeration), `menuSuffix(count:)`. Covered by unit tests.
- a thin `NSAlert` wrapper that runs the modal. Not covered.

Shape, English key set:

```
2 active sessions — quit anyway?
Affected: claude-rc-manager (1), website (1). Running phone sessions will
be cut off.
[Cancel] [Quit Anyway]
```

Cancel is added first and is therefore the default button: pressing Return
must not destroy anything. The single-folder "Stop" omits the enumeration,
because the folder is already named by the menu it was invoked from.

**Deliberately unchanged:** the existing Remove confirmation adds its
destructive button first (`StatusMenuController.swift:277`), so Return
confirms there. Reordering it changes behaviour that is not part of this
issue and is left alone.

## Call sites

The alert appears when the affected set has at least one active session;
otherwise the action runs unchanged.

| Site | Behaviour |
| --- | --- |
| `applicationShouldTerminate` (`main.swift:81`) | ask before `stopAll()`; on cancel return `.terminateCancel`; no server has been touched yet, so the cancellation is complete |
| "Stop" for one folder (`StatusMenuController.swift:239`) | ask for that folder only, no enumeration in the body |
| "Stop All" (`StatusMenuController.swift:328`) | ask for every folder with sessions |
| "Remove" (`StatusMenuController.swift:271`) | no second dialog: the existing confirmation gains one extra sentence naming the count |

Logout and restart are exempt: macOS calls the same method, and
`.terminateCancel` would cancel the user's logout. The quit reason is read
from the current Apple event (`kAEQuitReason` / `kAELogOut`); for a
system-initiated quit the servers are stopped without asking. Nothing is
lost by that: the sessions are local processes under the app
(`ProcessLauncher.swift:311`) and end with the login session either way.

## Menu

`statusLabel` (`StatusMenuController.swift:177`) appends the count when
`activeSessions >= 1`: `running · 2 Sessions`. Zero, including an unknown
count, leaves the row as it is today. The count is visible before the alert
appears, so the alert confirms something already seen.

## Localization

New keys in all seven `Sources/ClaudeRCManager/Resources/*.lproj/Localizable.strings`
(de, en, es, fr, it, ja, zh-Hans), following the existing `alert.*` and
`menu.*` naming. The table holds plain strings only, so every count-bearing
string gets a singular and a plural key:

| Key | Purpose |
| --- | --- |
| `alert.sessions.quit.title.one` / `.other` | quit title |
| `alert.sessions.stop.title.one` / `.other` | stop title |
| `alert.sessions.body.list` | body with `%@` enumeration |
| `alert.sessions.body` | body without enumeration |
| `alert.sessions.confirm.quit` / `.stop` | destructive button |
| `alert.sessions.cancel` | cancel button |
| `alert.remove.sessions.one` / `.other` | extra sentence in the Remove alert |
| `menu.sessions.one` / `.other` | menu row suffix |

The enumeration entries (`name (2)`) carry a bare number and need no pair.
Japanese and Chinese carry the same text in both keys of a pair; French uses
the singular for one.

## Limitations

- A session can start or end between the alert and the stop. The number
  shown is the last one reported, not a value queried at click time; there
  is no channel back to the server to ask.
- The number can be old. The CLI prints nothing while reconnecting or
  failed, and once a server is at capacity it re-polls only every 10
  minutes, so the last reported number can stand for that long.
- With "create session in dir" on (`SettingsWindow.swift:18`, off by
  default at `FolderConfig.swift:18`), the server pre-creates one session at
  startup and the count is 1 with nobody attached. That session is stopped
  like any other, so it is counted like any other: the alert stays truthful,
  at the price of appearing for such folders whenever they are stopped.

## Tests (`swift test`)

- Counter: count in one chunk, count split across two chunks, several counts
  in one chunk, no count, escape sequences around the count, a chunk longer
  than the carry-over ceiling.
- `sessionCount`: reset at run start, reset on exit, a report from a
  superseded counter ignored.
- `activeSessions`: stopped, active with unknown count, spawn mode
  `session`, reported count, spawn mode read from the run snapshot after a
  settings edit.
- `sessionEntries`: folders without sessions filtered out, config order kept.
- Text builder: one session against several, quit title against stop title,
  body with and without the enumeration, menu suffix at zero and above.
