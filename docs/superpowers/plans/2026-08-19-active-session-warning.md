# Active-Session Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ask before any action that stops a managed server would end running phone sessions, and show the session count in the menu.

**Architecture:** A parser reads the CLI's own `Capacity: N/M` line off the pty stream the app already reads, `ServerProcess` keeps the last number per run, and one shared count (`activeSessions`) feeds both the menu row and a confirmation alert wired into the four stop paths. All wording lives in pure functions so it can be unit-tested without a modal.

**Tech Stack:** Swift 5, SwiftPM, AppKit, XCTest. Spec: `docs/superpowers/specs/2026-08-19-active-session-warning-design.md`.

**Never run `make install`, `make reinstall`, `make uninstall`, or stop/start any server while implementing.** The maintainer's own phone session runs inside a server this app manages; those targets would kill it. `swift build` and `swift test` are safe and are the only verification this plan uses.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/ClaudeRCManager/SessionCounter.swift` (create) | Extract `Capacity: N/M` from pty chunks, report changes |
| `Sources/ClaudeRCManager/SessionAlertText.swift` (create) | Pure wording: titles, body, buttons, menu suffix |
| `Sources/ClaudeRCManager/SessionAlert.swift` (create) | The `NSAlert` modal, no logic |
| `Sources/ClaudeRCManager/ServerProcess.swift` (modify) | Own the per-run counter, expose `activeSessions` |
| `Sources/ClaudeRCManager/ServerManager.swift` (modify) | `SessionEntry`, aggregation across processes |
| `Sources/ClaudeRCManager/StatusMenuController.swift` (modify) | Menu suffix, Stop, Stop All, Remove |
| `Sources/ClaudeRCManager/main.swift` (modify) | Quit path, power-off exemption |
| `Sources/ClaudeRCManager/Resources/*.lproj/Localizable.strings` (modify, 7 files) | New keys |
| `Tests/ClaudeRCManagerTests/SessionCounterTests.swift` (create) | Parser cases |
| `Tests/ClaudeRCManagerTests/SessionAlertTextTests.swift` (create) | Wording cases |
| `Tests/ClaudeRCManagerTests/ServerProcessTests.swift` (modify) | Count lifecycle, `activeSessions` |
| `Tests/ClaudeRCManagerTests/ServerManagerTests.swift` (modify) | Aggregation |
| `Tests/ClaudeRCManagerTests/L10nTests.swift` (modify) | Key inventory |

---

### Task 1: SessionCounter

**Files:**
- Create: `Sources/ClaudeRCManager/SessionCounter.swift`
- Test: `Tests/ClaudeRCManagerTests/SessionCounterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRCManagerTests/SessionCounterTests.swift`:

```swift
import XCTest
@testable import ClaudeRCManager

final class SessionCounterTests: XCTestCase {
    /// Collects reports; the counter calls back on the feeding thread, and
    /// every test here feeds synchronously from the test thread.
    private func makeSUT() -> (SessionCounter, () -> [Int]) {
        let box = Box()
        let counter = SessionCounter()
        counter.onChange = { box.values.append($0) }
        return (counter, { box.values })
    }

    private final class Box { var values: [Int] = [] }

    private func feed(_ counter: SessionCounter, _ text: String) {
        counter.feed(Data(text.utf8))
    }

    func testLastCountInTextWins() {
        XCTAssertEqual(SessionCounter.lastCount(in: "Capacity: 0/32 … Capacity: 3/32"), 3)
    }

    func testNoCountReturnsNil() {
        XCTAssertNil(SessionCounter.lastCount(in: "Connecting · website · main"))
    }

    func testSpacingVariantIsMatched() {
        XCTAssertEqual(SessionCounter.lastCount(in: "Capacity:  7/32"), 7)
    }

    func testEscapeSequencesAroundTheCountAreIgnored() {
        let text = "\u{1B}[32mCapacity: 2\u{1B}[0m/32"
        let (counter, values) = makeSUT()
        feed(counter, text)
        XCTAssertEqual(values(), [2])
    }

    func testChangeIsReportedOnceUntilItChanges() {
        let (counter, values) = makeSUT()
        feed(counter, "Capacity: 1/32\n")
        feed(counter, "Capacity: 1/32\n")
        feed(counter, "Capacity: 2/32\n")
        XCTAssertEqual(values(), [1, 2])
    }

    func testMatchSplitAcrossTwoChunks() {
        let (counter, values) = makeSUT()
        feed(counter, "…Capa")
        feed(counter, "city: 4/32 · New sessions")
        XCTAssertEqual(values(), [4])
    }

    func testLongChunkWithoutAMatchDoesNotBreakTheNextOne() {
        let (counter, values) = makeSUT()
        feed(counter, String(repeating: "x", count: 10_000))
        feed(counter, "Capacity: 5/32")
        XCTAssertEqual(values(), [5])
    }

    /// Fails if the carry-over were unbounded: the "Capa" prefix is pushed
    /// out of the retained tail by the filler, so the split must not match.
    func testFragmentOlderThanTheCarryOverIsDropped() {
        let (counter, values) = makeSUT()
        feed(counter, "Capa")
        feed(counter, String(repeating: "x", count: SessionCounter.carryOver))
        feed(counter, "city: 8/32")
        XCTAssertEqual(values(), [])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SessionCounterTests`
Expected: compile error, `cannot find 'SessionCounter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ClaudeRCManager/SessionCounter.swift`:

```swift
import Foundation

/// Reads the session count the CLI prints on every redraw
/// (`Capacity: <live>/<max>`) out of one server's pty stream.
///
/// Fed from the pty reader thread, like the LogWriter, so the mutable state
/// sits behind a lock. `onChange` is called on the feeding thread and only
/// when the number actually changes; the receiver hops to the main actor.
final class SessionCounter: @unchecked Sendable {
    /// Characters kept from the end of a chunk so a `Capacity: 2/32` split
    /// across two reads is still matched. Comfortably longer than the match.
    static let carryOver = 256

    private static let pattern = try! NSRegularExpression(
        pattern: "Capacity: *([0-9]+)/[0-9]+")

    private let lock = NSLock()
    private var pending = ""
    private var count: Int?

    /// Set once, before the server is launched, so no feed can race it.
    var onChange: ((Int) -> Void)?

    /// The last count in `text`, or nil when there is none.
    static func lastCount(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.matches(in: text, range: range).last,
              let digits = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[digits])
    }

    /// The tail carried into the next chunk.
    static func tail(of text: String) -> String {
        String(text.suffix(carryOver))
    }

    func feed(_ chunk: Data) {
        var report: Int?
        lock.lock()
        // Filtering first: the stream carries ANSI escapes, which can sit
        // between "Capacity:" and the digits. Re-filtering the carried-over
        // tail is harmless, it holds no escapes any more.
        let text = LogWriter.filter(pending + String(decoding: chunk, as: UTF8.self))
        if let value = Self.lastCount(in: text), value != count {
            count = value
            report = value
        }
        pending = Self.tail(of: text)
        lock.unlock()
        if let report { onChange?(report) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SessionCounterTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/SessionCounter.swift Tests/ClaudeRCManagerTests/SessionCounterTests.swift
git commit -m "Read the session count out of the server's pty stream"
```

---

### Task 2: ServerProcess keeps the count per run

**Files:**
- Modify: `Sources/ClaudeRCManager/ServerProcess.swift`
- Test: `Tests/ClaudeRCManagerTests/ServerProcessTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ClaudeRCManagerTests/ServerProcessTests.swift`, inside the class:

```swift
    // MARK: session count

    func testCountFromOutputIsApplied() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ sp.sessionCount == 2 }, "reported count must be applied")
        XCTAssertEqual(sp.activeSessions, 2)
    }

    func testUnknownCountMeansNoSessions() async throws {
        let (sp, _) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        XCTAssertNil(sp.sessionCount)
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testStoppedServerHasNoSessions() {
        let (sp, _) = makeSUT()
        XCTAssertEqual(sp.state, .stopped)
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testSessionSpawnModeCountsAsOne() async throws {
        let (sp, _) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        XCTAssertNil(sp.sessionCount)
        XCTAssertEqual(sp.activeSessions, 1)
    }

    func testSpawnModeIsReadFromTheRunSnapshot() async throws {
        let (sp, _) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        var edited = sp.folder
        edited.spawnMode = .worktree
        sp.update(folder: edited)
        XCTAssertEqual(sp.activeSessions, 1,
                       "an edit during the run must not change how this run counts")
    }

    func testCountIsClearedOnExit() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 3/32".utf8))
        try await waitFor({ sp.sessionCount == 3 }, "reported count must be applied")
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.sessionCount == nil }, "exit must clear the count")
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testWaitingForARestartHasNoSessions() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ sp.sessionCount == 2 }, "reported count must be applied")
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.state == .restarting }, "must schedule a restart")
        // .restarting counts as active, but no process is running.
        XCTAssertEqual(sp.activeSessions, 0)
    }

    func testReportFromASupersededRunIsIgnored() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "must reach running")
        let firstRun = launcher.servers[0]
        launcher.servers[0].exitNow(1)
        try await waitFor({ sp.state == .failed("exited, status 1") }, "must fail")
        sp.start(manual: true)
        try await waitFor({ sp.state == .running }, "second run must reach running")
        // The old run's pty chunk arrives late.
        firstRun.onOutput?(Data("Capacity: 9/32".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(sp.sessionCount, "a superseded run must not set the count")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ServerProcessTests`
Expected: compile error, `value of type 'ServerProcess' has no member 'sessionCount'`.

- [ ] **Step 3: Write the implementation**

In `Sources/ClaudeRCManager/ServerProcess.swift`, add the stored state next to `launchedFolder` (around line 79):

```swift
    /// Last count the running server reported, nil while unknown. Cleared
    /// when a run ends, which is the only place it needs clearing: a new run
    /// can only start once the previous one is over.
    private(set) var sessionCount: Int?
    /// One counter per run: a chunk can still be in flight when a run ends,
    /// and its report must not survive into the next one.
    private var counter: SessionCounter?
```

In `start()`, replace the launch block (currently `let argv = …` through `self.server = server`) with:

```swift
            let argv = CommandBuilder.argv(for: folder, claudePath: claudePath)
            let counter = SessionCounter()
            self.counter = counter
            // [weak counter]: the counter owns this closure, so a strong
            // capture would keep one counter per run alive for the app's life.
            counter.onChange = { [weak self, weak counter] value in
                Task { @MainActor [weak self, weak counter] in
                    guard let counter else { return }
                    self?.apply(count: value, from: counter)
                }
            }
            let server = try launcher.launch(
                argv: argv, workingDirectory: folder.path,
                onOutput: { [writer, counter] data in
                    writer?.append(data)
                    counter.feed(data)
                },
                onExit: { [weak self] status in
                    // Inner capture list copies the weak binding: older
                    // compilers (CI's macos-14 Swift) reject referencing the
                    // outer mutable weak var from a concurrent closure.
                    Task { @MainActor [weak self] in self?.handleExit(status: status) }
                })
            self.server = server
```

Add next to `handleExit`:

```swift
    /// Ignores a report from a superseded run.
    private func apply(count: Int, from source: SessionCounter) {
        guard source === counter else { return }
        sessionCount = count
    }
```

In `handleExit`, right after `server = nil`, add:

```swift
        sessionCount = nil
        counter = nil
```

Add below `pids` / `innerPid` (around line 205):

```swift
    /// Sessions running inside this server, as far as the app can know.
    /// The single number the menu row and the stop warning both use.
    var activeSessions: Int {
        // The run's own snapshot, the same rule handleExit follows: a settings
        // edit mid-run must not change how this run is counted. No snapshot
        // means no live run (waiting out a restart backoff), hence no sessions.
        guard state.isActive, let ranAs = launchedFolder else { return 0 }
        // Session mode prints no capacity line: the server is the session.
        if ranAs.spawnMode == .session { return 1 }
        return sessionCount ?? 0
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ServerProcessTests`
Expected: PASS, all tests including the seven new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/ServerProcess.swift Tests/ClaudeRCManagerTests/ServerProcessTests.swift
git commit -m "Keep the reported session count per server run"
```

---

### Task 3: ServerManager aggregation

**Files:**
- Modify: `Sources/ClaudeRCManager/ServerManager.swift`
- Test: `Tests/ClaudeRCManagerTests/ServerManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ClaudeRCManagerTests/ServerManagerTests.swift`, inside the class:

```swift
    // MARK: session entries

    /// Two existing folders with distinct names, both autostarting.
    private func twoNamedFolders() -> [FolderConfig] {
        var a = validFolder()
        a.name = "alpha"
        var b = validFolder()
        b.name = "beta"
        return [a, b]
    }

    func testSessionEntriesSkipFoldersWithoutSessions() async throws {
        let (mgr, launcher) = makeSUT(folders: twoNamedFolders())
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes.allSatisfy { $0.state == .running } }, "both must run")
        launcher.servers[0].onOutput?(Data("Capacity: 2/32".utf8))
        try await waitFor({ mgr.processes[0].sessionCount == 2 }, "count must arrive")
        XCTAssertEqual(mgr.activeSessionEntries, [SessionEntry(name: "alpha", count: 2)])
    }

    func testSessionEntriesKeepConfigOrder() async throws {
        let (mgr, launcher) = makeSUT(folders: twoNamedFolders())
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes.allSatisfy { $0.state == .running } }, "both must run")
        launcher.servers[1].onOutput?(Data("Capacity: 1/32".utf8))
        launcher.servers[0].onOutput?(Data("Capacity: 3/32".utf8))
        try await waitFor({ mgr.activeSessionEntries.count == 2 }, "both counts must arrive")
        XCTAssertEqual(mgr.activeSessionEntries,
                       [SessionEntry(name: "alpha", count: 3),
                        SessionEntry(name: "beta", count: 1)])
    }

    func testSessionEntriesOfASubset() async throws {
        let (mgr, launcher) = makeSUT(folders: twoNamedFolders())
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await waitFor({ mgr.processes.allSatisfy { $0.state == .running } }, "both must run")
        launcher.servers[1].onOutput?(Data("Capacity: 1/32".utf8))
        try await waitFor({ mgr.processes[1].sessionCount == 1 }, "count must arrive")
        XCTAssertEqual(ServerManager.sessionEntries(of: [mgr.processes[1]]),
                       [SessionEntry(name: "beta", count: 1)])
        XCTAssertEqual(ServerManager.sessionEntries(of: [mgr.processes[0]]), [])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ServerManagerTests`
Expected: compile error, `cannot find 'SessionEntry' in scope`.

- [ ] **Step 3: Write the implementation**

In `Sources/ClaudeRCManager/ServerManager.swift`, above the class:

```swift
/// One folder's share of the sessions an action would end.
struct SessionEntry: Equatable {
    let name: String
    let count: Int
}
```

Inside the class, next to `ownPids()`:

```swift
    /// Folders with at least one session, in the order they are configured.
    /// Servers whose count is still unknown are not listed (spec: unknown
    /// counts as none).
    static func sessionEntries(of processes: [ServerProcess]) -> [SessionEntry] {
        processes.compactMap { p in
            let count = p.activeSessions
            return count >= 1 ? SessionEntry(name: p.folder.name, count: count) : nil
        }
    }

    var activeSessionEntries: [SessionEntry] { Self.sessionEntries(of: processes) }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ServerManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/ServerManager.swift Tests/ClaudeRCManagerTests/ServerManagerTests.swift
git commit -m "Aggregate the session count across servers"
```

---

### Task 4: Localized strings

**Files:**
- Modify: all seven `Sources/ClaudeRCManager/Resources/*.lproj/Localizable.strings`
- Modify: `Tests/ClaudeRCManagerTests/L10nTests.swift`

The plural rule: `.one` carries no format argument, `.other` carries `%d`.
`LocalizationParityTests` compares the argument multiset per key across
locales, so this split must be identical in all seven files.

- [ ] **Step 1: Extend the key inventory test**

In `Tests/ClaudeRCManagerTests/L10nTests.swift`, in `testEveryInventoryKeyIsPresent`, add to the `keys` array after the `alert.loginItem.*` line:

```swift
            "alert.sessions.quit.title.one", "alert.sessions.quit.title.other",
            "alert.sessions.stop.title.one", "alert.sessions.stop.title.other",
            "alert.sessions.body.list", "alert.sessions.body",
            "alert.sessions.confirm.quit", "alert.sessions.confirm.stop",
            "alert.sessions.cancel",
            "alert.remove.sessions.one", "alert.remove.sessions.other",
            "menu.sessions.one", "menu.sessions.other",
```

And in `testEnglishBaseValues`, add:

```swift
        XCTAssertEqual(try english("alert.sessions.quit.title.other"),
                       "Quit with %d active sessions?")
        XCTAssertEqual(try english("menu.sessions.one"), "· 1 Session")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter L10nTests`
Expected: two failures, both from the missing keys — `testEnglishBaseValues`
comparing nil against the expected English string, and
`testEveryInventoryKeyIsPresent` reporting `missing en value for
alert.sessions.quit.title.one`.

- [ ] **Step 3: Add the keys**

Append to `Sources/ClaudeRCManager/Resources/en.lproj/Localizable.strings`:

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "Quit with 1 active session?";
"alert.sessions.quit.title.other" = "Quit with %d active sessions?";
"alert.sessions.stop.title.one" = "Stop with 1 active session?";
"alert.sessions.stop.title.other" = "Stop with %d active sessions?";
"alert.sessions.body.list" = "Affected: %@. Running phone sessions end immediately.";
"alert.sessions.body" = "Running phone sessions end immediately.";
"alert.sessions.confirm.quit" = "Quit Anyway";
"alert.sessions.confirm.stop" = "Stop Anyway";
"alert.sessions.cancel" = "Cancel";
"alert.remove.sessions.one" = "This folder has 1 active session. It ends with the server.";
"alert.remove.sessions.other" = "This folder has %d active sessions. They end with the server.";
"menu.sessions.one" = "· 1 Session";
"menu.sessions.other" = "· %d Sessions";
```

`de.lproj` (the catalog says "Sitzung" for a session, see `settings.createSessionInDir`):

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "Mit 1 aktiven Sitzung beenden?";
"alert.sessions.quit.title.other" = "Mit %d aktiven Sitzungen beenden?";
"alert.sessions.stop.title.one" = "Mit 1 aktiven Sitzung stoppen?";
"alert.sessions.stop.title.other" = "Mit %d aktiven Sitzungen stoppen?";
"alert.sessions.body.list" = "Betroffen: %@. Laufende Sitzungen auf dem Telefon enden sofort.";
"alert.sessions.body" = "Laufende Sitzungen auf dem Telefon enden sofort.";
"alert.sessions.confirm.quit" = "Trotzdem beenden";
"alert.sessions.confirm.stop" = "Trotzdem stoppen";
"alert.sessions.cancel" = "Abbrechen";
"alert.remove.sessions.one" = "In diesem Ordner läuft 1 aktive Sitzung. Sie endet mit dem Server.";
"alert.remove.sessions.other" = "In diesem Ordner laufen %d aktive Sitzungen. Sie enden mit dem Server.";
"menu.sessions.one" = "· 1 Sitzung";
"menu.sessions.other" = "· %d Sitzungen";
```

`fr.lproj`:

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "Quitter avec 1 session active ?";
"alert.sessions.quit.title.other" = "Quitter avec %d sessions actives ?";
"alert.sessions.stop.title.one" = "Arrêter avec 1 session active ?";
"alert.sessions.stop.title.other" = "Arrêter avec %d sessions actives ?";
"alert.sessions.body.list" = "Concernés : %@. Les sessions en cours sur le téléphone se terminent immédiatement.";
"alert.sessions.body" = "Les sessions en cours sur le téléphone se terminent immédiatement.";
"alert.sessions.confirm.quit" = "Quitter quand même";
"alert.sessions.confirm.stop" = "Arrêter quand même";
"alert.sessions.cancel" = "Annuler";
"alert.remove.sessions.one" = "Ce dossier a 1 session active. Elle se termine avec le serveur.";
"alert.remove.sessions.other" = "Ce dossier a %d sessions actives. Elles se terminent avec le serveur.";
"menu.sessions.one" = "· 1 session";
"menu.sessions.other" = "· %d sessions";
```

`es.lproj`:

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "¿Salir con 1 sesión activa?";
"alert.sessions.quit.title.other" = "¿Salir con %d sesiones activas?";
"alert.sessions.stop.title.one" = "¿Detener con 1 sesión activa?";
"alert.sessions.stop.title.other" = "¿Detener con %d sesiones activas?";
"alert.sessions.body.list" = "Afectados: %@. Las sesiones en curso en el teléfono terminan de inmediato.";
"alert.sessions.body" = "Las sesiones en curso en el teléfono terminan de inmediato.";
"alert.sessions.confirm.quit" = "Salir de todos modos";
"alert.sessions.confirm.stop" = "Detener de todos modos";
"alert.sessions.cancel" = "Cancelar";
"alert.remove.sessions.one" = "Esta carpeta tiene 1 sesión activa. Termina con el servidor.";
"alert.remove.sessions.other" = "Esta carpeta tiene %d sesiones activas. Terminan con el servidor.";
"menu.sessions.one" = "· 1 sesión";
"menu.sessions.other" = "· %d sesiones";
```

`it.lproj`:

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "Uscire con 1 sessione attiva?";
"alert.sessions.quit.title.other" = "Uscire con %d sessioni attive?";
"alert.sessions.stop.title.one" = "Arrestare con 1 sessione attiva?";
"alert.sessions.stop.title.other" = "Arrestare con %d sessioni attive?";
"alert.sessions.body.list" = "Interessati: %@. Le sessioni in corso sul telefono terminano subito.";
"alert.sessions.body" = "Le sessioni in corso sul telefono terminano subito.";
"alert.sessions.confirm.quit" = "Esci comunque";
"alert.sessions.confirm.stop" = "Arresta comunque";
"alert.sessions.cancel" = "Annulla";
"alert.remove.sessions.one" = "Questa cartella ha 1 sessione attiva. Termina con il server.";
"alert.remove.sessions.other" = "Questa cartella ha %d sessioni attive. Terminano con il server.";
"menu.sessions.one" = "· 1 sessione";
"menu.sessions.other" = "· %d sessioni";
```

`ja.lproj`:

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "アクティブなセッションが1件あります。終了しますか？";
"alert.sessions.quit.title.other" = "アクティブなセッションが%d件あります。終了しますか？";
"alert.sessions.stop.title.one" = "アクティブなセッションが1件あります。停止しますか？";
"alert.sessions.stop.title.other" = "アクティブなセッションが%d件あります。停止しますか？";
"alert.sessions.body.list" = "対象: %@。実行中のスマートフォンのセッションはすぐに終了します。";
"alert.sessions.body" = "実行中のスマートフォンのセッションはすぐに終了します。";
"alert.sessions.confirm.quit" = "終了する";
"alert.sessions.confirm.stop" = "停止する";
"alert.sessions.cancel" = "キャンセル";
"alert.remove.sessions.one" = "このフォルダにはアクティブなセッションが1件あります。サーバーとともに終了します。";
"alert.remove.sessions.other" = "このフォルダにはアクティブなセッションが%d件あります。サーバーとともに終了します。";
"menu.sessions.one" = "· 1 セッション";
"menu.sessions.other" = "· %d セッション";
```

`zh-Hans.lproj`:

```
/* MARK: active-session warning */
"alert.sessions.quit.title.one" = "有 1 个活动会话，仍要退出吗？";
"alert.sessions.quit.title.other" = "有 %d 个活动会话，仍要退出吗？";
"alert.sessions.stop.title.one" = "有 1 个活动会话，仍要停止吗？";
"alert.sessions.stop.title.other" = "有 %d 个活动会话，仍要停止吗？";
"alert.sessions.body.list" = "受影响：%@。手机上正在进行的会话会立即结束。";
"alert.sessions.body" = "手机上正在进行的会话会立即结束。";
"alert.sessions.confirm.quit" = "仍然退出";
"alert.sessions.confirm.stop" = "仍然停止";
"alert.sessions.cancel" = "取消";
"alert.remove.sessions.one" = "此文件夹有 1 个活动会话，会随服务器一起结束。";
"alert.remove.sessions.other" = "此文件夹有 %d 个活动会话，会随服务器一起结束。";
"menu.sessions.one" = "· 1 个会话";
"menu.sessions.other" = "· %d 个会话";
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "L10nTests|LocalizationParityTests"`
Expected: PASS. A parity failure names the offending key and locale; fix the file it names.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/Resources Tests/ClaudeRCManagerTests/L10nTests.swift
git commit -m "Add the wording for the active-session warning in all seven languages"
```

---

### Task 5: SessionAlertText

**Files:**
- Create: `Sources/ClaudeRCManager/SessionAlertText.swift`
- Test: `Tests/ClaudeRCManagerTests/SessionAlertTextTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeRCManagerTests/SessionAlertTextTests.swift`:

```swift
import XCTest
@testable import ClaudeRCManager

/// Language-agnostic on purpose: `swift test` negotiates the system
/// language, so the assertions check structure and substitution, not
/// English wording. The English wording itself is asserted in L10nTests.
final class SessionAlertTextTests: XCTestCase {
    func testTitleUsesTheSingularKeyForOne() {
        XCTAssertEqual(SessionAlertText.title(scope: .quit, count: 1),
                       L10n.t("alert.sessions.quit.title.one"))
        XCTAssertEqual(SessionAlertText.title(scope: .stop, count: 1),
                       L10n.t("alert.sessions.stop.title.one"))
    }

    func testTitleUsesThePluralKeyAndSubstitutesTheCount() {
        let title = SessionAlertText.title(scope: .quit, count: 3)
        XCTAssertEqual(title, L10n.t("alert.sessions.quit.title.other", Int32(3)))
        XCTAssertTrue(title.contains("3"))
    }

    func testQuitAndStopTitlesDiffer() {
        XCTAssertNotEqual(SessionAlertText.title(scope: .quit, count: 2),
                          SessionAlertText.title(scope: .stop, count: 2))
    }

    func testBodyEnumeratesFoldersWithTheirCounts() {
        let body = SessionAlertText.body(entries: [
            SessionEntry(name: "alpha", count: 2),
            SessionEntry(name: "beta", count: 1),
        ])
        XCTAssertTrue(body.contains("alpha (2), beta (1)"), body)
    }

    func testBodyWithoutEntriesOmitsTheEnumeration() {
        XCTAssertEqual(SessionAlertText.body(entries: []), L10n.t("alert.sessions.body"))
    }

    func testConfirmButtonDiffersByScope() {
        XCTAssertEqual(SessionAlertText.confirm(scope: .quit),
                       L10n.t("alert.sessions.confirm.quit"))
        XCTAssertNotEqual(SessionAlertText.confirm(scope: .quit),
                          SessionAlertText.confirm(scope: .stop))
    }

    func testMenuSuffixIsNilBelowOne() {
        XCTAssertNil(SessionAlertText.menuSuffix(count: 0))
        XCTAssertNotNil(SessionAlertText.menuSuffix(count: 1))
    }

    func testMenuSuffixSubstitutesThePluralCount() throws {
        let suffix = try XCTUnwrap(SessionAlertText.menuSuffix(count: 4))
        XCTAssertEqual(suffix, L10n.t("menu.sessions.other", Int32(4)))
    }

    /// The alert's only real decision, kept here so it is testable: the
    /// modal itself has no unit test.
    func testTotalAndWarningThreshold() {
        XCTAssertEqual(SessionAlertText.total(of: []), 0)
        XCTAssertFalse(SessionAlertText.needsWarning(entries: []))
        let entries = [SessionEntry(name: "alpha", count: 2),
                       SessionEntry(name: "beta", count: 1)]
        XCTAssertEqual(SessionAlertText.total(of: entries), 3)
        XCTAssertTrue(SessionAlertText.needsWarning(entries: entries))
    }

    func testRemoveSentenceIsNilWithoutSessions() {
        XCTAssertNil(SessionAlertText.removeSentence(count: 0))
        XCTAssertEqual(SessionAlertText.removeSentence(count: 1),
                       L10n.t("alert.remove.sessions.one"))
        XCTAssertEqual(SessionAlertText.removeSentence(count: 2),
                       L10n.t("alert.remove.sessions.other", Int32(2)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SessionAlertTextTests`
Expected: compile error, `cannot find 'SessionAlertText' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/ClaudeRCManager/SessionAlertText.swift`:

```swift
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

    /// With entries the body names the folders; without them the folder is
    /// already known from where the action was invoked.
    static func body(entries: [SessionEntry]) -> String {
        guard !entries.isEmpty else { return L10n.t("alert.sessions.body") }
        let list = entries.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
        return L10n.t("alert.sessions.body.list", list)
    }

    static func confirm(scope: Scope) -> String { L10n.t(scope.confirmKey) }

    /// Sessions an action would end.
    static func total(of entries: [SessionEntry]) -> Int {
        entries.reduce(0) { $0 + $1.count }
    }

    /// Whether the action needs confirming at all.
    static func needsWarning(entries: [SessionEntry]) -> Bool {
        total(of: entries) >= 1
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SessionAlertTextTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/SessionAlertText.swift Tests/ClaudeRCManagerTests/SessionAlertTextTests.swift
git commit -m "Build the warning wording from folder counts"
```

---

### Task 6: The modal and the menu call sites

**Files:**
- Create: `Sources/ClaudeRCManager/SessionAlert.swift`
- Modify: `Sources/ClaudeRCManager/StatusMenuController.swift` (`statusLabel`/`folderItem` around 177-196, `toggleServer` 239, `removeFolder` 271, `stopAllAction` 328)

No unit tests: `NSAlert.runModal` needs a user. Everything decidable was
covered in Tasks 3 and 5.

- [ ] **Step 1: Write the modal**

Create `Sources/ClaudeRCManager/SessionAlert.swift`:

```swift
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
        // Cancel first, so it is the default button: Return must not destroy
        // anything.
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
```

- [ ] **Step 2: Wire the menu row**

In `Sources/ClaudeRCManager/StatusMenuController.swift`, replace the title
line in `folderItem` (line 192):

```swift
            title: "\(folder.name)   \(statusLabel(process.state))",
```

with:

```swift
            title: "\(folder.name)   \(rowLabel(for: process))",
```

and add below `statusLabel`:

```swift
    /// State plus the session count, when the server reported one.
    private func rowLabel(for process: ServerProcess) -> String {
        let state = statusLabel(process.state)
        guard let suffix = SessionAlertText.menuSuffix(count: process.activeSessions) else {
            return state
        }
        return "\(state) \(suffix)"
    }
```

- [ ] **Step 3: Wire Stop, Stop All and Remove**

In `toggleServer`, replace the stop branch:

```swift
        if process.state.isActive {
            process.stop()
```

with:

```swift
        if process.state.isActive {
            guard SessionAlert.confirm(scope: .stop,
                                       entries: ServerManager.sessionEntries(of: [process]),
                                       enumerate: false) else { return }
            process.stop()
```

Replace `stopAllAction` (line 328):

```swift
    @objc private func stopAllAction() { manager.stopAll() }
```

with:

```swift
    @objc private func stopAllAction() {
        guard SessionAlert.confirm(scope: .stop, entries: manager.activeSessionEntries)
        else { return }
        manager.stopAll()
    }
```

In `removeFolder`, replace the button block (lines 277-280):

```swift
        alert.addButton(withTitle: L10n.t("alert.remove.confirm"))
        alert.addButton(withTitle: L10n.t("alert.remove.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
```

with:

```swift
        // Cancel first, like the sessions warning: the more destructive of
        // the two dialogs must not have the riskier default.
        alert.addButton(withTitle: L10n.t("alert.remove.cancel"))
        alert.addButton(withTitle: L10n.t("alert.remove.confirm"))
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
```

And replace the informative-text line (line 276):

```swift
        alert.informativeText = L10n.t("alert.remove.body")
```

with:

```swift
        // One dialog, not two: the sessions warning joins the existing
        // confirmation instead of stacking on top of it.
        if let sessions = SessionAlertText.removeSentence(count: process.activeSessions) {
            alert.informativeText = sessions + " " + L10n.t("alert.remove.body")
        } else {
            alert.informativeText = L10n.t("alert.remove.body")
        }
```

- [ ] **Step 4: Build and run the whole suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/SessionAlert.swift Sources/ClaudeRCManager/StatusMenuController.swift
git commit -m "Ask before Stop, Stop All and Remove end active sessions"
```

---

### Task 7: The quit path

**Files:**
- Modify: `Sources/ClaudeRCManager/main.swift` (`applicationShouldTerminate` 81)

Logout, restart and shutdown reach the same delegate method as a normal
quit. The quit reason travels with the Apple event that triggered it and is
readable synchronously. `NSWorkspace.willPowerOffNotification` is not usable
here: it is delivered through the main queue and can land after
`applicationShouldTerminate` has already asked and cancelled the logout.

- [ ] **Step 1: Read the quit reason**

In `Sources/ClaudeRCManager/main.swift`, add below `import AppKit`:

```swift
import CoreServices
```

and add to `AppDelegate`, next to `didReplyToTerminate`:

```swift
    /// True when macOS is quitting the app as part of a logout, restart or
    /// shutdown. Cancelling there would cancel the user's logout, and the
    /// sessions end with the login session either way, so those never ask.
    ///
    /// Read from the event that triggered the quit rather than from
    /// NSWorkspace.willPowerOffNotification: that notification is delivered
    /// through the main queue and can arrive after this method has run.
    private var isSystemInitiatedQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return false }
        switch reason.enumCodeValue {
        case UInt32(kAELogOut), UInt32(kAEReallyLogOut),
             UInt32(kAEShowRestartDialog), UInt32(kAERestart),
             UInt32(kAEShowShutdownDialog), UInt32(kAEShutDown):
            return true
        default:
            return false
        }
    }
```

This exact code was compiled on this machine before the plan was written
(`swiftc` with `import AppKit` and `import CoreServices`, exit 0). A
rejected constant means the `import CoreServices` is missing, not that the
constant is wrong.

- [ ] **Step 2: Ask before stopping**

Replace the head of `applicationShouldTerminate`:

```swift
        guard let manager, manager.anyActive else { return .terminateNow }
        manager.stopAll()
```

with:

```swift
        guard let manager, manager.anyActive else { return .terminateNow }
        // Nothing has been signalled yet, so cancelling here is complete.
        if !isSystemInitiatedQuit,
           !SessionAlert.confirm(scope: .quit, entries: manager.activeSessionEntries)
        {
            return .terminateCancel
        }
        manager.stopAll()
```

- [ ] **Step 3: Build and run the whole suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRCManager/main.swift
git commit -m "Ask before quitting ends active sessions, except at logout"
```

---

### Task 8: Documentation and close-out

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Describe the behaviour**

In `README.md`, in the **Usage** list, add after the per-folder bullet
(`- Per folder: **Start/Stop**, …`):

```markdown
- **Sessions** — a folder's row shows how many sessions its server reports
  (`● running · 2 Sessions`). Stop, Stop All, Remove… and Quit ask
  before they end running sessions.
```

In the **Limitations** list, add after the force-quit bullet:

```markdown
- A server that has not reported a session count yet counts as empty, so a
  stop in the first seconds after a start does not ask.
- Logout, restart and shutdown stop the servers without asking; the sessions
  end with the login session either way.
```

- [ ] **Step 2: Verify the full suite one more time**

Run: `swift build && swift test`
Expected: the summary line reads `Executed N tests, with 0 failures`. Do not
pipe this through `tail`: the pipeline would report the exit code of `tail`,
not of the test run.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document the active-session warning"
```

- [ ] **Step 4: Hand over for a real run**

The maintainer runs the app; this plan must not. Report what needs checking
by hand: the menu row for a folder with a live session, the alert on Stop,
on Stop All, on Remove and on Quit, and that Cancel really leaves the
servers running.
