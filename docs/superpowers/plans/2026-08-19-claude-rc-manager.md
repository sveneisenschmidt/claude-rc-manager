# Claude RC Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app (SwiftPM, macOS 13+) that starts/stops one `claude remote-control` server per configured folder, per the spec in `docs/superpowers/specs/2026-08-19-claude-rc-manager-design.md`.

**Architecture:** Pure-logic components (config, tokenizer, command builder, backoff, parsers, log filter) are separate files with XCTest coverage. Process handling sits behind a `ProcessLaunching` protocol so `ServerProcess`/`ServerManager` are testable with fakes. AppKit `NSStatusItem` menu + SwiftUI settings forms are thin, manually tested layers on top.

**Tech Stack:** Swift 5.9, SwiftPM (no Xcode project), AppKit + SwiftUI, XCTest, `/usr/bin/script` for the pty, `SMAppService` for the login item.

**Branch note:** The repo has no remote yet. Work directly on `main` with frequent commits; the PR flow starts once the GitHub remote exists.

**Read the spec first.** Every behavior below is normative there. On any conflict, the spec wins.

---

## File structure

```
Package.swift
Sources/ClaudeRCManager/
  main.swift                  # entry point, AppDelegate, single-instance, wiring
  FolderConfig.swift          # models: AppConfig, FolderConfig, enums
  ConfigStore.swift           # JSON persistence, atomic write, corrupt recovery
  ArgsTokenizer.swift         # POSIX-like extra-args tokenizer
  CommandBuilder.swift        # FolderConfig -> argv
  AuthStatus.swift            # `claude auth status` JSON parsing
  ClaudeCLI.swift             # binary resolution, auth check with timeout
  LogWriter.swift             # ANSI/CR filter, append, 5 MB rotation
  Backoff.swift               # backoff sequence + crash-loop counter
  ProcessLauncher.swift       # ProcessLaunching protocol + ScriptLauncher (real)
  ServerProcess.swift         # per-folder state machine
  ServerManager.swift         # owns ServerProcesses, autostart, stop-all
  ExternalServerScanner.swift # pgrep/lsof parsing + scan
  StatusIcon.swift            # pure aggregation: states -> icon bucket
  StatusMenuController.swift  # NSStatusItem + NSMenu (manual test)
  SettingsWindow.swift        # SwiftUI per-folder form in NSWindow (manual test)
  LoginItem.swift             # SMAppService wrapper (manual test)
Tests/ClaudeRCManagerTests/
  FolderConfigTests.swift
  ConfigStoreTests.swift
  ArgsTokenizerTests.swift
  CommandBuilderTests.swift
  AuthStatusTests.swift
  LogWriterTests.swift
  BackoffTests.swift
  ScriptLauncherTests.swift
  ServerProcessTests.swift
  ServerManagerTests.swift
  ClaudeCLITests.swift
  ExternalServerScannerTests.swift
  StatusIconTests.swift
Makefile
Resources/Info.plist
README.md
LICENSE
.gitignore
.github/workflows/build.yml
.github/workflows/release.yml
```

---

### Task 1: SwiftPM scaffold

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/ClaudeRCManager/main.swift`
- Create: `Tests/ClaudeRCManagerTests/FolderConfigTests.swift` (placeholder assert to prove the test target runs)

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeRCManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeRCManager",
            path: "Sources/ClaudeRCManager"
        ),
        .testTarget(
            name: "ClaudeRCManagerTests",
            dependencies: ["ClaudeRCManager"],
            path: "Tests/ClaudeRCManagerTests"
        ),
    ]
)
```

- [ ] **Step 2: Write .gitignore**

```
.build/
*.app
.DS_Store
.swiftpm/
```

- [ ] **Step 3: Write minimal main.swift**

```swift
import AppKit

// Wiring grows in later tasks; top-level code is only allowed in main.swift.
// swift test works with this file present: XCTest loads the module without
// executing main (verified by compile probe).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Write a smoke test**

`Tests/ClaudeRCManagerTests/FolderConfigTests.swift`:

```swift
import XCTest

final class FolderConfigTests: XCTestCase {
    func testTargetBuilds() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test`
Expected: build succeeds, 1 test passes.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "Scaffold SwiftPM executable and test target"
```

---

### Task 2: Models (FolderConfig, AppConfig)

**Files:**
- Create: `Sources/ClaudeRCManager/FolderConfig.swift`
- Modify: `Tests/ClaudeRCManagerTests/FolderConfigTests.swift`

- [ ] **Step 1: Write failing tests**

Replace `FolderConfigTests.swift`:

```swift
import XCTest
@testable import ClaudeRCManager

final class FolderConfigTests: XCTestCase {
    func testDefaults() {
        let f = FolderConfig(path: "/tmp/proj")
        XCTAssertEqual(f.name, "proj")
        XCTAssertEqual(f.spawnMode, .sameDir)
        XCTAssertFalse(f.createSessionInDir) // standby default
        XCTAssertEqual(f.capacity, 32)
        XCTAssertNil(f.permissionMode)
        XCTAssertEqual(f.extraArgs, "")
        XCTAssertFalse(f.autostart)
        XCTAssertTrue(f.autoRestart)
    }

    func testCodableRoundTrip() throws {
        var f = FolderConfig(path: "/tmp/proj")
        f.spawnMode = .worktree
        f.permissionMode = .acceptEdits
        let config = AppConfig(folders: [f])
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back, config)
        XCTAssertEqual(back.version, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `cannot find 'FolderConfig' in scope`

- [ ] **Step 3: Implement models**

`Sources/ClaudeRCManager/FolderConfig.swift`:

```swift
import Foundation

enum SpawnMode: String, Codable, CaseIterable {
    case sameDir = "same-dir"
    case worktree
    case session
}

enum PermissionMode: String, Codable, CaseIterable {
    case acceptEdits, auto, bypassPermissions, `default`, dontAsk, plan
}

struct FolderConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var name: String
    var spawnMode: SpawnMode = .sameDir
    var createSessionInDir = false
    var capacity = 32
    var permissionMode: PermissionMode?
    var extraArgs = ""
    var autostart = false
    var autoRestart = true

    init(path: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
    }
}

struct AppConfig: Codable, Equatable {
    var version = 1
    var folders: [FolderConfig] = []
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/FolderConfig.swift Tests/ClaudeRCManagerTests/FolderConfigTests.swift
git commit -m "Add FolderConfig and AppConfig models"
```

---

### Task 3: ConfigStore

**Files:**
- Create: `Sources/ClaudeRCManager/ConfigStore.swift`
- Create: `Tests/ClaudeRCManagerTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class ConfigStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileYieldsEmptyConfig() {
        let store = ConfigStore(directory: dir)
        XCTAssertEqual(store.load(), .fresh(AppConfig()))
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = ConfigStore(directory: dir)
        var config = AppConfig()
        config.folders.append(FolderConfig(path: "/tmp/a"))
        try store.save(config)
        XCTAssertEqual(store.load(), .fresh(config))
    }

    func testCorruptFileIsRenamedAndEmptyConfigReturned() throws {
        let file = dir.appendingPathComponent("config.json")
        try Data("not json{{".utf8).write(to: file)
        let store = ConfigStore(directory: dir)
        XCTAssertEqual(store.load(), .recoveredFromCorrupt(AppConfig()))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigStoreTests`
Expected: FAIL — `cannot find 'ConfigStore' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/ConfigStore.swift`:

```swift
import Foundation

/// Persists AppConfig as JSON. Atomic writes; a corrupt file is moved to
/// config.json.bak and an empty config returned (spec: ConfigStore).
final class ConfigStore {
    enum LoadResult: Equatable {
        case fresh(AppConfig)
        case recoveredFromCorrupt(AppConfig)
    }

    private let fileURL: URL
    private let backupURL: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude RC Manager")
    }

    init(directory: URL = ConfigStore.defaultDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("config.json")
        backupURL = directory.appendingPathComponent("config.json.bak")
    }

    func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .fresh(AppConfig())
        }
        if let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return .fresh(config)
        }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        return .recoveredFromCorrupt(AppConfig())
    }

    func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        // Atomic: write to temp in the same directory, then rename over.
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigStoreTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/ConfigStore.swift Tests/ClaudeRCManagerTests/ConfigStoreTests.swift
git commit -m "Add ConfigStore with atomic save and corrupt-file recovery"
```

---

### Task 4: ArgsTokenizer

**Files:**
- Create: `Sources/ClaudeRCManager/ArgsTokenizer.swift`
- Create: `Tests/ClaudeRCManagerTests/ArgsTokenizerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class ArgsTokenizerTests: XCTestCase {
    func testEmpty() {
        XCTAssertEqual(ArgsTokenizer.tokenize(""), [])
        XCTAssertEqual(ArgsTokenizer.tokenize("   "), [])
    }

    func testWhitespaceSplit() {
        XCTAssertEqual(ArgsTokenizer.tokenize("--debug-file /tmp/x.log"),
                       ["--debug-file", "/tmp/x.log"])
    }

    func testDoubleQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"--name "My Project""#),
                       ["--name", "My Project"])
    }

    func testSingleQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize("--name 'a b'"), ["--name", "a b"])
    }

    func testBackslashEscape() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"a\ b c"#), ["a b", "c"])
    }

    func testNoExpansion() {
        XCTAssertEqual(ArgsTokenizer.tokenize("~/x $HOME"), ["~/x", "$HOME"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ArgsTokenizerTests`
Expected: FAIL — `cannot find 'ArgsTokenizer' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/ArgsTokenizer.swift`:

```swift
import Foundation

/// POSIX-like tokenizer for the per-folder extra-args field (spec:
/// Per-folder configuration). Whitespace splits; ' and " quote; \ escapes
/// the next character outside single quotes. No tilde/glob/variable
/// expansion — tokens go to argv directly, no shell involved.
enum ArgsTokenizer {
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasContent = false
        var it = input.makeIterator()
        var quote: Character? = nil

        while let c = it.next() {
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\" && q == "\"" {
                    current.append(it.next() ?? "\\")
                } else {
                    current.append(c)
                }
            } else if c == "'" || c == "\"" {
                quote = c
                hasContent = true
            } else if c == "\\" {
                current.append(it.next() ?? "\\")
                hasContent = true
            } else if c == " " || c == "\t" {
                if hasContent || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(c)
            }
        }
        if hasContent || !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ArgsTokenizerTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/ArgsTokenizer.swift Tests/ClaudeRCManagerTests/ArgsTokenizerTests.swift
git commit -m "Add POSIX-like tokenizer for extra args"
```

---

### Task 5: CommandBuilder

**Files:**
- Create: `Sources/ClaudeRCManager/CommandBuilder.swift`
- Create: `Tests/ClaudeRCManagerTests/CommandBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class CommandBuilderTests: XCTestCase {
    func testDefaultStandbyCommand() {
        let f = FolderConfig(path: "/tmp/proj")
        let argv = CommandBuilder.argv(for: f, claudePath: "/usr/local/bin/claude")
        XCTAssertEqual(argv, [
            "/usr/bin/script", "-q", "/dev/null",
            "/usr/local/bin/claude", "remote-control",
            "--name", "proj",
            "--spawn", "same-dir",
            "--capacity", "32",
            "--no-create-session-in-dir",
        ])
    }

    func testWorktreeModeWithQuotedExtraArgs() {
        var f = FolderConfig(path: "/tmp/proj")
        f.spawnMode = .worktree
        f.extraArgs = #"--debug-file "/tmp/my logs/rc.log""#
        let argv = CommandBuilder.argv(for: f, claudePath: "/x/claude")
        XCTAssertEqual(argv, [
            "/usr/bin/script", "-q", "/dev/null",
            "/x/claude", "remote-control",
            "--name", "proj",
            "--spawn", "worktree",
            "--capacity", "32",
            "--no-create-session-in-dir",
            "--debug-file", "/tmp/my logs/rc.log",
        ])
    }

    func testSessionModeOmitsCapacityAndKeepsFlags() {
        var f = FolderConfig(path: "/tmp/proj")
        f.spawnMode = .session
        f.createSessionInDir = true
        f.permissionMode = .plan
        f.extraArgs = "--verbose"
        let argv = CommandBuilder.argv(for: f, claudePath: "/x/claude")
        XCTAssertEqual(argv, [
            "/usr/bin/script", "-q", "/dev/null",
            "/x/claude", "remote-control",
            "--name", "proj",
            "--spawn", "session",
            "--create-session-in-dir",
            "--permission-mode", "plan",
            "--verbose",
        ])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandBuilderTests`
Expected: FAIL — `cannot find 'CommandBuilder' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/CommandBuilder.swift`:

```swift
import Foundation

/// Builds the argv for one folder's server (spec: Command and process tree).
/// `script` supplies the pty; capacity is omitted in session mode (the CLI
/// scopes it to worktree/same-dir); extra args are appended last.
enum CommandBuilder {
    static func argv(for folder: FolderConfig, claudePath: String) -> [String] {
        var argv = [
            "/usr/bin/script", "-q", "/dev/null",
            claudePath, "remote-control",
            "--name", folder.name,
            "--spawn", folder.spawnMode.rawValue,
        ]
        if folder.spawnMode != .session {
            argv += ["--capacity", String(folder.capacity)]
        }
        argv.append(folder.createSessionInDir
            ? "--create-session-in-dir"
            : "--no-create-session-in-dir")
        if let mode = folder.permissionMode {
            argv += ["--permission-mode", mode.rawValue]
        }
        argv += ArgsTokenizer.tokenize(folder.extraArgs)
        return argv
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CommandBuilderTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/CommandBuilder.swift Tests/ClaudeRCManagerTests/CommandBuilderTests.swift
git commit -m "Add argv builder for remote-control servers"
```

---

### Task 6: AuthStatus parser

**Files:**
- Create: `Sources/ClaudeRCManager/AuthStatus.swift`
- Create: `Tests/ClaudeRCManagerTests/AuthStatusTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class AuthStatusTests: XCTestCase {
    func testLoggedIn() {
        let json = Data(#"{"loggedIn": true, "authMethod": "claude.ai"}"#.utf8)
        XCTAssertTrue(AuthStatus.isLoggedIn(json))
    }

    func testLoggedOut() {
        XCTAssertFalse(AuthStatus.isLoggedIn(Data(#"{"loggedIn": false}"#.utf8)))
    }

    func testInvalidJSONMeansLoggedOut() {
        XCTAssertFalse(AuthStatus.isLoggedIn(Data("garbage".utf8)))
    }

    func testMissingFieldMeansLoggedOut() {
        XCTAssertFalse(AuthStatus.isLoggedIn(Data(#"{"email": "x@y.z"}"#.utf8)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AuthStatusTests`
Expected: FAIL — `cannot find 'AuthStatus' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/AuthStatus.swift`:

```swift
import Foundation

/// Parses `claude auth status` output. Anything but a parseable JSON object
/// with `"loggedIn": true` counts as logged out (spec: ClaudeCLI).
enum AuthStatus {
    private struct Payload: Decodable { let loggedIn: Bool }

    static func isLoggedIn(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Payload.self, from: data))?.loggedIn ?? false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AuthStatusTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/AuthStatus.swift Tests/ClaudeRCManagerTests/AuthStatusTests.swift
git commit -m "Add auth-status JSON parsing"
```

---

### Task 7: LogWriter (ANSI/CR filter + rotation)

**Files:**
- Create: `Sources/ClaudeRCManager/LogWriter.swift`
- Create: `Tests/ClaudeRCManagerTests/LogWriterTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class LogWriterTests: XCTestCase {
    func testStripsCSISequences() {
        XCTAssertEqual(LogWriter.filter("\u{1B}[31mRED\u{1B}[0m\r\n"), "RED\n")
    }

    func testStripsOSCSequences() {
        XCTAssertEqual(LogWriter.filter("\u{1B}]0;title\u{07}text"), "text")
    }

    func testDropsCarriageReturnsAndBackspaces() {
        XCTAssertEqual(LogWriter.filter("a\u{08}b\rline\r\n"), "abline\n")
    }

    func testRotationAtThreshold() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.log")
        try Data(repeating: 65, count: 10).write(to: file)

        LogWriter.rotateIfNeeded(at: file, maxBytes: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".old"))

        // Under the threshold: nothing happens.
        try Data(repeating: 66, count: 3).write(to: file)
        LogWriter.rotateIfNeeded(at: file, maxBytes: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LogWriterTests`
Expected: FAIL — `cannot find 'LogWriter' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/LogWriter.swift`:

```swift
import Foundation

/// Appends a server's pty output to its log file. The pty stream contains
/// ANSI escapes and CR overwrites (spec: Command and process tree); filter
/// them so the log is readable in a text editor.
final class LogWriter {
    private let handle: FileHandle
    let url: URL

    /// CSI (ESC [ ... final byte), OSC (ESC ] ... BEL or ESC \), other
    /// two-byte ESC sequences, then lone CR and BS characters.
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-_]|[\r\u{08}]"
    )

    static func filter(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    static func rotateIfNeeded(at url: URL, maxBytes: Int = 5 * 1024 * 1024) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = URL(fileURLWithPath: url.path + ".old")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        LogWriter.rotateIfNeeded(at: url)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func append(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        let filtered = LogWriter.filter(text)
        if let data = filtered.data(using: .utf8), !data.isEmpty {
            handle.write(data)
        }
    }

    deinit { try? handle.close() }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LogWriterTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/LogWriter.swift Tests/ClaudeRCManagerTests/LogWriterTests.swift
git commit -m "Add log writer with ANSI/CR filtering and rotation"
```

---

### Task 8: Backoff + crash-loop counter

**Files:**
- Create: `Sources/ClaudeRCManager/Backoff.swift`
- Create: `Tests/ClaudeRCManagerTests/BackoffTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class BackoffTests: XCTestCase {
    func testDelaySequenceCapsAt60() {
        var p = RestartPolicy()
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 2))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 4))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 8))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 16))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 32))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 60))
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 60))
    }

    func testCrashLoopPausesOnThirdFastExit() {
        var p = RestartPolicy()
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 2), .restart(after: 2))
        XCTAssertEqual(p.recordExit(runDuration: 1), .crashLoopPause)
    }

    func testSlowExitResetsCrashLoopCounterButNotBackoff() {
        var p = RestartPolicy()
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 2))
        // 10 s run: not a fast exit, crash-loop counter resets,
        // backoff keeps growing (only a >= 5 min run resets it).
        XCTAssertEqual(p.recordExit(runDuration: 10), .restart(after: 4))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 8))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 16))
        XCTAssertEqual(p.recordExit(runDuration: 1), .crashLoopPause)
    }

    func testStableRunResetsEverything() {
        var p = RestartPolicy()
        _ = p.recordExit(runDuration: 1)
        _ = p.recordExit(runDuration: 1)
        XCTAssertEqual(p.recordExit(runDuration: 301), .restart(after: 1))
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 2))
    }

    func testManualStartResets() {
        var p = RestartPolicy()
        _ = p.recordExit(runDuration: 1)
        _ = p.recordExit(runDuration: 1)
        p.reset()
        XCTAssertEqual(p.recordExit(runDuration: 1), .restart(after: 1))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BackoffTests`
Expected: FAIL — `cannot find 'RestartPolicy' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/Backoff.swift`:

```swift
import Foundation

/// Restart decisions after an unexpected exit (spec: Crash handling).
/// Crash-loop check first: 3 consecutive exits each within `fastExitWindow`
/// of start pause auto-restart. Otherwise back off 1,2,4,... capped at 60 s.
/// A run of >= `stableRunDuration` resets both counters; `reset()` is the
/// manual-start reset.
struct RestartPolicy: Equatable {
    enum Decision: Equatable {
        case restart(after: TimeInterval)
        case crashLoopPause
    }

    var fastExitWindow: TimeInterval = 5
    var stableRunDuration: TimeInterval = 300
    private var attempt = 0
    private var consecutiveFastExits = 0

    mutating func recordExit(runDuration: TimeInterval) -> Decision {
        if runDuration >= stableRunDuration {
            attempt = 0
            consecutiveFastExits = 0
        }
        if runDuration < fastExitWindow {
            consecutiveFastExits += 1
            if consecutiveFastExits >= 3 {
                return .crashLoopPause
            }
        } else {
            consecutiveFastExits = 0
        }
        attempt += 1
        let delay = min(60, pow(2, Double(attempt - 1)))
        return .restart(after: delay)
    }

    mutating func reset() {
        attempt = 0
        consecutiveFastExits = 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BackoffTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/Backoff.swift Tests/ClaudeRCManagerTests/BackoffTests.swift
git commit -m "Add restart policy with backoff and crash-loop pause"
```

---

### Task 9: ProcessLauncher protocol + ScriptLauncher

**Files:**
- Create: `Sources/ClaudeRCManager/ProcessLauncher.swift`
- Create: `Tests/ClaudeRCManagerTests/ScriptLauncherTests.swift`

The real launcher is exercised by `ServerProcessTests` (Task 10) through the
protocol and by one direct integration test here.

- [ ] **Step 1: Implement the protocol and the real launcher**

`Sources/ClaudeRCManager/ProcessLauncher.swift`:

```swift
import Foundation

/// One running server's process handle, as seen by ServerProcess.
protocol RunningServer: AnyObject {
    /// pid of the inner claude process (script's child), once resolved.
    var innerPid: pid_t? { get }
    /// All pids of this server's tree (script + inner child), for the
    /// external-scan exclusion.
    var pids: [pid_t] { get }
    /// Called once when the process tree exits, with script's status.
    var onExit: ((Int32) -> Void)? { get set }
    /// Called with raw output chunks (pty stream).
    var onOutput: ((Data) -> Void)? { get set }
    /// SIGTERM to the inner process group; SIGKILL after `gracePeriod`.
    func stop(gracePeriod: TimeInterval)
    /// Immediate SIGKILL to everything (quit deadline).
    func kill()
}

protocol ProcessLaunching {
    func launch(argv: [String], workingDirectory: String) throws -> RunningServer
}

/// Real launcher: runs `script -q /dev/null ...`. Verified reality (spec:
/// Command and process tree): script's child sits in its OWN session and
/// process group, so signals must target the inner pid, which we resolve
/// via pgrep -P. stdin is /dev/null (script fails on socket stdin).
final class ScriptLauncher: ProcessLaunching {
    final class Server: RunningServer {
        let process = Process()
        var onExit: ((Int32) -> Void)?
        var onOutput: ((Data) -> Void)?
        private let queue = DispatchQueue(label: "server-process")
        private let lock = NSLock()
        private var _innerPid: pid_t?

        var innerPid: pid_t? {
            lock.lock(); defer { lock.unlock() }
            return _innerPid
        }

        var pids: [pid_t] {
            var result = [process.processIdentifier]
            if let inner = innerPid { result.append(inner) }
            return result
        }

        private func setInnerPid(_ pid: pid_t) {
            lock.lock(); _innerPid = pid; lock.unlock()
        }

        /// Blocking retry on `queue`; also used by stop() so a stop right
        /// after launch still finds the inner pid before signaling.
        private func resolveInnerPidBlocking() -> pid_t? {
            if let pid = innerPid { return pid }
            let scriptPid = process.processIdentifier
            for _ in 0..<20 {
                if let pid = Self.childPid(of: scriptPid) {
                    setInnerPid(pid)
                    return pid
                }
                if !process.isRunning { return nil }
                usleep(100_000)
            }
            return nil
        }

        fileprivate func resolveInnerPid() {
            queue.async { [weak self] in _ = self?.resolveInnerPidBlocking() }
        }

        static func childPid(of parent: pid_t) -> pid_t? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", String(parent)]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").first else { return nil }
            return pid_t(line.trimmingCharacters(in: .whitespaces))
        }

        func stop(gracePeriod: TimeInterval) {
            queue.async { [weak self] in
                guard let self else { return }
                // Wait for the inner pid if it has not resolved yet —
                // signaling only script would orphan the inner claude.
                if let pid = self.resolveInnerPidBlocking() {
                    // Inner pid is its own group leader (login_tty session).
                    killpg(pid, SIGTERM)
                }
                if self.process.isRunning { self.process.terminate() }
            }
            queue.asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
                guard let self, self.process.isRunning else { return }
                self.kill()
            }
        }

        func kill() {
            if let pid = innerPid, process.isRunning { killpg(pid, SIGKILL) }
            if process.isRunning {
                // script is not a group leader; signal the pid directly.
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func launch(argv: [String], workingDirectory: String) throws -> RunningServer {
        precondition(!argv.isEmpty)
        let server = Server()
        let p = server.process
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak server] handle in
            let data = handle.availableData
            if !data.isEmpty { server?.onOutput?(data) }
        }
        p.terminationHandler = { [weak server] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            server?.onExit?(proc.terminationStatus)
        }
        try p.run()
        server.resolveInnerPid()
        return server
    }
}
```

- [ ] **Step 2: Add an integration test against a real process**

Create `Tests/ClaudeRCManagerTests/ScriptLauncherTests.swift`:

```swift
import XCTest
@testable import ClaudeRCManager

final class ScriptLauncherTests: XCTestCase {
    func testLaunchResolvesInnerPidAndStops() throws {
        let launcher = ScriptLauncher()
        let server = try launcher.launch(
            argv: ["/usr/bin/script", "-q", "/dev/null", "/bin/sleep", "30"],
            workingDirectory: NSTemporaryDirectory())

        let exited = expectation(description: "exit")
        server.onExit = { _ in exited.fulfill() }

        // Inner pid resolves within ~2 s.
        var inner: pid_t?
        for _ in 0..<30 {
            if let pid = server.innerPid { inner = pid; break }
            usleep(100_000)
        }
        XCTAssertNotNil(inner, "inner pid must resolve")

        server.stop(gracePeriod: 2)
        wait(for: [exited], timeout: 5)
        // The inner sleep itself must be gone (kill 0 = existence probe).
        usleep(200_000)
        XCTAssertEqual(Darwin.kill(inner!, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
```

- [ ] **Step 3: Run the test**

Run: `swift test --filter ScriptLauncherTests`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRCManager/ProcessLauncher.swift Tests/ClaudeRCManagerTests/ScriptLauncherTests.swift
git commit -m "Add process launcher with inner-pid signal targeting"
```

---

### Task 10: ServerProcess state machine

**Files:**
- Create: `Sources/ClaudeRCManager/ServerProcess.swift`
- Create: `Tests/ClaudeRCManagerTests/ServerProcessTests.swift`

- [ ] **Step 1: Write failing tests (with a fake launcher)**

```swift
import XCTest
@testable import ClaudeRCManager

final class FakeServer: RunningServer {
    var innerPid: pid_t? = 4242
    var pids: [pid_t] { [111, 4242] } // 111 stands in for the script pid
    var onExit: ((Int32) -> Void)?
    var onOutput: ((Data) -> Void)?
    var stopped = false
    var killed = false
    func stop(gracePeriod: TimeInterval) { stopped = true }
    func kill() { killed = true }
    func exitNow(_ status: Int32) { onExit?(status) }
}

final class FakeLauncher: ProcessLaunching {
    var servers: [FakeServer] = []
    var launchCount = 0
    var error: Error?
    func launch(argv: [String], workingDirectory: String) throws -> RunningServer {
        if let error { throw error }
        launchCount += 1
        let s = FakeServer()
        servers.append(s)
        return s
    }
}

@MainActor
final class ServerProcessTests: XCTestCase {
    func makeSUT(spawnMode: SpawnMode = .sameDir, autoRestart: Bool = true)
        -> (ServerProcess, FakeLauncher)
    {
        var f = FolderConfig(path: NSTemporaryDirectory())
        f.spawnMode = spawnMode
        f.autoRestart = autoRestart
        let launcher = FakeLauncher()
        let sp = ServerProcess(
            folder: f, launcher: launcher,
            logDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            claudePath: "/bin/echo",
            readinessDelay: 0.05,
            backoffScale: 0.01)
        return (sp, launcher)
    }

    /// onExit hops onto the main actor via an enqueued Task; yield so the
    /// queued task runs before asserting.
    func drainMainQueue() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    func testStartReachesRunningAfterReadinessDelay() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sp.state, .running)
    }

    func testUserStopGoesToStoppedWithoutRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        sp.stop()
        XCTAssertEqual(sp.state, .stopping)
        launcher.servers[0].exitNow(0)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .stopped)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testUnexpectedExitSchedulesRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(1)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .restarting)
    }

    func testStopDuringRestartingCancelsTimerAndStops() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(1)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .restarting)
        sp.stop()
        XCTAssertEqual(sp.state, .stopped)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(launcher.launchCount, 1) // no restart fired
    }

    func testCrashLoopPauseThenManualStartClears() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(1) // fast exit 1 -> backoff restart
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[1].exitNow(1) // fast exit 2 -> backoff restart
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[2].exitNow(1) // fast exit 3 -> pause
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .failed("crash loop — check log"))
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .starting)
        XCTAssertEqual(launcher.launchCount, 4)
    }

    func testSessionModeExitZeroIsEnded() async throws {
        let (sp, launcher) = makeSUT(spawnMode: .session)
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(0)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .ended)
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testAutoRestartOffGoesToFailed() async throws {
        let (sp, launcher) = makeSUT(autoRestart: false)
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        launcher.servers[0].exitNow(3)
        try await drainMainQueue()
        XCTAssertEqual(sp.state, .failed("exited, status 3"))
    }

    func testPreflightFailureBlocksRestart() async throws {
        let (sp, launcher) = makeSUT()
        sp.start(manual: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        sp.preflight = { "not logged in" }
        launcher.servers[0].exitNow(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sp.state, .failed("not logged in"))
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testLaunchErrorIsFailed() {
        let (sp, launcher) = makeSUT()
        launcher.error = NSError(domain: "x", code: 1)
        sp.start(manual: true)
        XCTAssertEqual(sp.state, .failed("launch error"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ServerProcessTests`
Expected: FAIL — `cannot find 'ServerProcess' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/ServerProcess.swift`:

```swift
import Foundation

enum ServerState: Equatable {
    case stopped, starting, running, stopping, restarting, ended
    case failed(String)

    var isActive: Bool {
        switch self {
        case .starting, .running, .stopping, .restarting: return true
        default: return false
        }
    }

    /// States a (bulk) start may act on.
    var canStart: Bool {
        switch self {
        case .stopped, .ended, .failed: return true
        default: return false
        }
    }
}

/// State machine for one folder's server (spec: States, Crash handling).
/// Main-thread confined; all callbacks hop to the main queue.
@MainActor
final class ServerProcess {
    private(set) var folder: FolderConfig
    private(set) var state: ServerState = .stopped {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((ServerState) -> Void)?

    private let launcher: ProcessLaunching
    private let logDirectory: URL
    /// Settable: the real path resolves asynchronously after app launch.
    var claudePath: String
    /// Re-checked before every start, including auto-restarts (spec: Start
    /// preconditions). Returns a failure reason or nil. Set by ServerManager.
    var preflight: (() -> String?)?
    private let readinessDelay: TimeInterval
    private let backoffScale: Double
    private var server: RunningServer?
    private var logWriter: LogWriter?
    private var policy = RestartPolicy()
    private var startedAt: Date?
    private var restartTask: Task<Void, Never>?
    private var userStopRequested = false

    var logURL: URL {
        logDirectory.appendingPathComponent("\(folder.id.uuidString).log")
    }

    init(folder: FolderConfig, launcher: ProcessLaunching, logDirectory: URL,
         claudePath: String, readinessDelay: TimeInterval = 5,
         backoffScale: Double = 1)
    {
        self.folder = folder
        self.launcher = launcher
        self.logDirectory = logDirectory
        self.claudePath = claudePath
        self.readinessDelay = readinessDelay
        self.backoffScale = backoffScale
    }

    func update(folder: FolderConfig) {
        // Settings apply on next start (spec: SettingsWindow).
        self.folder = folder
    }

    func start(manual: Bool) {
        guard !state.isActive else { return }
        if manual { policy.reset() }
        userStopRequested = false
        if let reason = preflight?() {
            state = .failed(reason) // precondition failures skip policy accounting
            return
        }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            state = .failed("folder missing")
            return
        }
        do {
            logWriter = try? LogWriter(url: logURL)
            let argv = CommandBuilder.argv(for: folder, claudePath: claudePath)
            let server = try launcher.launch(argv: argv, workingDirectory: folder.path)
            self.server = server
            startedAt = Date()
            state = .starting
            server.onOutput = { [weak self] data in
                self?.logWriter?.append(data)
            }
            server.onExit = { [weak self] status in
                Task { @MainActor in self?.handleExit(status: status) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.readinessDelay ?? 5) * 1e9))
                if self?.state == .starting { self?.state = .running }
            }
        } catch {
            state = .failed("launch error")
        }
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        if state == .restarting {
            state = .stopped
            return
        }
        guard state.isActive, let server else { return }
        userStopRequested = true
        state = .stopping
        server.stop(gracePeriod: 5)
    }

    func killNow() {
        restartTask?.cancel()
        server?.kill()
    }

    private func handleExit(status: Int32) {
        server = nil
        let runDuration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if userStopRequested {
            state = .stopped
            return
        }
        if folder.spawnMode == .session {
            state = .ended // the CLI exits when the session ends: expected
            return
        }
        guard folder.autoRestart else {
            state = .failed("exited, status \(status)")
            return
        }
        switch policy.recordExit(runDuration: runDuration) {
        case .crashLoopPause:
            state = .failed("crash loop — check log")
        case .restart(let delay):
            state = .restarting
            let scaled = delay * backoffScale
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(scaled * 1e9))
                guard let self, self.state == .restarting else { return }
                self.start(manual: false)
            }
        }
    }

    // Used by ServerManager and the external-scan exclusion.
    var pids: [pid_t] { server?.pids ?? [] }
    var innerPid: pid_t? { server?.innerPid }

    func setPreconditionFailure(_ reason: String) {
        guard !state.isActive else { return }
        state = .failed(reason)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ServerProcessTests`
Expected: PASS (9 tests)

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all green

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeRCManager/ServerProcess.swift Tests/ClaudeRCManagerTests/ServerProcessTests.swift
git commit -m "Add per-folder server state machine"
```

---

### Task 11: ClaudeCLI (binary resolution + auth check)

**Files:**
- Create: `Sources/ClaudeRCManager/ClaudeCLI.swift`

Binary resolution and subprocess timeout touch the real system; the JSON
logic is already covered by `AuthStatusTests`. One integration test verifies
resolution on this machine.

- [ ] **Step 1: Implement**

`Sources/ClaudeRCManager/ClaudeCLI.swift`:

```swift
import Foundation

/// Finds the claude binary and checks login state (spec: ClaudeCLI).
/// GUI apps inherit no shell PATH, so resolution runs a login shell once;
/// re-resolves on demand while unresolved. Auth result is cached for 60 s.
final class ClaudeCLI {
    private(set) var binaryPath: String?
    private var lastAuth: (loggedIn: Bool, at: Date)?

    /// Runs a command with a timeout; returns stdout or nil on any failure.
    static func run(_ argv: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 ? data : nil
    }

    @discardableResult
    func resolveBinary() -> String? {
        if let binaryPath { return binaryPath }
        guard let data = ClaudeCLI.run(
            ["/bin/zsh", "-lc", "command -v claude"], timeout: 10),
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        binaryPath = path
        return path
    }

    /// Cached for 60 s (spec: Login check). Call off the main thread.
    func isLoggedIn(force: Bool = false) -> Bool {
        if !force, let last = lastAuth, Date().timeIntervalSince(last.at) < 60 {
            return last.loggedIn
        }
        guard let claude = resolveBinary(),
              let data = ClaudeCLI.run([claude, "auth", "status"], timeout: 5)
        else {
            lastAuth = (false, Date())
            return false
        }
        let result = AuthStatus.isLoggedIn(data)
        lastAuth = (result, Date())
        return result
    }

    /// Opens Terminal running `claude auth login` (interactive OAuth).
    func openLoginInTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude auth login"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
```

- [ ] **Step 2: Add integration test**

`Tests/ClaudeRCManagerTests/ClaudeCLITests.swift`:

```swift
import XCTest
@testable import ClaudeRCManager

final class ClaudeCLITests: XCTestCase {
    func testRunReturnsStdout() {
        let data = ClaudeCLI.run(["/bin/echo", "hi"], timeout: 5)
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "hi\n")
    }

    func testRunTimesOut() {
        let start = Date()
        XCTAssertNil(ClaudeCLI.run(["/bin/sleep", "30"], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunNonzeroExitReturnsNil() {
        XCTAssertNil(ClaudeCLI.run(["/usr/bin/false"], timeout: 5))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter ClaudeCLITests`
Expected: PASS (3 tests)

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeRCManager/ClaudeCLI.swift Tests/ClaudeRCManagerTests/ClaudeCLITests.swift
git commit -m "Add claude binary resolution and auth check"
```

---

### Task 12: ExternalServerScanner

**Files:**
- Create: `Sources/ClaudeRCManager/ExternalServerScanner.swift`
- Create: `Tests/ClaudeRCManagerTests/ExternalServerScannerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class ExternalServerScannerTests: XCTestCase {
    func testParsePgrepFiltersAndExcludesOwnPids() {
        let output = """
        123 /Users/x/.local/bin/claude remote-control --spawn same-dir
        456 grep remote-control
        789 /usr/local/bin/claude remote-control
        999 /Users/x/.local/bin/claude remote-control
        """
        let hits = ExternalServerScanner.parsePgrep(output, excluding: [999])
        XCTAssertEqual(hits.map(\.pid), [123, 789])
        XCTAssertTrue(hits[0].command.contains("remote-control"))
    }

    func testParseLsofCwd() {
        let output = "p123\nfcwd\nn/Users/x/proj\n"
        XCTAssertEqual(ExternalServerScanner.parseLsofCwd(output), "/Users/x/proj")
    }

    func testParseLsofCwdMissing() {
        XCTAssertNil(ExternalServerScanner.parseLsofCwd("p123\n"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ExternalServerScannerTests`
Expected: FAIL — `cannot find 'ExternalServerScanner' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/ExternalServerScanner.swift`:

```swift
import Foundation

/// Finds remote-control servers this app did not start (spec: External
/// servers). Display only. Output formats verified 2026-08-19:
/// `pgrep -fl` prints "pid command...", lsof -Fn prints p<pid>/fcwd/n<path>.
struct ExternalServer: Equatable {
    let pid: pid_t
    let command: String
    var workingDirectory: String?
}

enum ExternalServerScanner {
    static func parsePgrep(_ output: String, excluding ownPids: Set<pid_t>) -> [ExternalServer] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = pid_t(parts[0]),
                  !ownPids.contains(pid) else { return nil }
            let command = String(parts[1])
            // Require the claude binary itself, not e.g. a grep of the term.
            guard command.contains("claude"),
                  command.contains("remote-control") else { return nil }
            return ExternalServer(pid: pid, command: command)
        }
    }

    static func parseLsofCwd(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// Blocking; call off the main thread (menu opens trigger it).
    static func scan(excluding ownPids: Set<pid_t>) -> [ExternalServer] {
        guard let data = ClaudeCLI.run(
            ["/usr/bin/pgrep", "-U", String(getuid()), "-fl", "remote-control"],
            timeout: 5),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        return parsePgrep(text, excluding: ownPids).map { server in
            var server = server
            if let out = ClaudeCLI.run(
                ["/usr/sbin/lsof", "-a", "-p", String(server.pid), "-d", "cwd", "-Fn"],
                timeout: 5),
               let text = String(data: out, encoding: .utf8)
            {
                server.workingDirectory = parseLsofCwd(text)
            }
            return server
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ExternalServerScannerTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/ExternalServerScanner.swift Tests/ClaudeRCManagerTests/ExternalServerScannerTests.swift
git commit -m "Add external-server detection (display only)"
```

---

### Task 13: StatusIcon aggregation

**Files:**
- Create: `Sources/ClaudeRCManager/StatusIcon.swift`
- Create: `Tests/ClaudeRCManagerTests/StatusIconTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

final class StatusIconTests: XCTestCase {
    func testWarningBeatsEverything() {
        XCTAssertEqual(StatusIcon.bucket(states: [.running, .failed("x")],
                                         healthy: true), .warning)
        XCTAssertEqual(StatusIcon.bucket(states: [.running], healthy: false), .warning)
    }

    func testActiveWhenAnythingRuns() {
        for s in [ServerState.starting, .running, .stopping, .restarting] {
            XCTAssertEqual(StatusIcon.bucket(states: [.stopped, s], healthy: true), .active)
        }
    }

    func testNeutralOtherwise() {
        XCTAssertEqual(StatusIcon.bucket(states: [.stopped, .ended], healthy: true), .neutral)
        XCTAssertEqual(StatusIcon.bucket(states: [], healthy: true), .neutral)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StatusIconTests`
Expected: FAIL — `cannot find 'StatusIcon' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/StatusIcon.swift`:

```swift
import Foundation

/// Icon aggregation (spec: Menu structure). `healthy` is false when not
/// logged in, the binary is missing, or the config was corrupt.
enum StatusIcon {
    enum Bucket: Equatable {
        case warning, active, neutral

        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .active: return "terminal.fill"
            case .neutral: return "terminal"
            }
        }
    }

    static func bucket(states: [ServerState], healthy: Bool) -> Bucket {
        if !healthy { return .warning }
        if states.contains(where: { if case .failed = $0 { return true }; return false }) {
            return .warning
        }
        if states.contains(where: \.isActive) { return .active }
        return .neutral
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StatusIconTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/StatusIcon.swift Tests/ClaudeRCManagerTests/StatusIconTests.swift
git commit -m "Add status-icon aggregation"
```

---

### Task 14: ServerManager

**Files:**
- Create: `Sources/ClaudeRCManager/ServerManager.swift`
- Create: `Tests/ClaudeRCManagerTests/ServerManagerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import ClaudeRCManager

@MainActor
final class ServerManagerTests: XCTestCase {
    func makeSUT() -> (ServerManager, FakeLauncher) {
        let launcher = FakeLauncher()
        var config = AppConfig()
        var a = FolderConfig(path: NSTemporaryDirectory())
        a.autostart = true
        var b = FolderConfig(path: NSTemporaryDirectory() + "/nope-\(UUID())")
        b.autostart = true
        config.folders = [a, b]
        let mgr = ServerManager(
            config: config, launcher: launcher,
            logDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            readinessDelay: 0.05)
        return (mgr, launcher)
    }

    func testAutostartStartsOnlyExistingFolders() {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(mgr.processes[1].state, .failed("folder missing"))
    }

    func testAutostartSkippedWhenLoggedOut() {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: false)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(mgr.processes[0].state, .failed("not logged in"))
    }

    func testStopAllStopsRunning() async throws {
        let (mgr, launcher) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        mgr.stopAll()
        XCTAssertTrue(launcher.servers[0].stopped)
    }

    func testOwnPidsListsScriptAndInnerPids() {
        let (mgr, _) = makeSUT()
        mgr.autostart(claudePath: "/bin/echo", loggedIn: true)
        XCTAssertEqual(mgr.ownPids(), [111, 4242]) // FakeServer.pids
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ServerManagerTests`
Expected: FAIL — `cannot find 'ServerManager' in scope`

- [ ] **Step 3: Implement**

`Sources/ClaudeRCManager/ServerManager.swift`:

```swift
import Foundation

/// Owns all ServerProcess instances (spec: ServerManager). Autostart on
/// launch, bulk start/stop, quit coordination, pid bookkeeping for the
/// external-server scan.
@MainActor
final class ServerManager {
    private(set) var processes: [ServerProcess] = []
    var onAnyStateChange: (() -> Void)?

    private let launcher: ProcessLaunching
    private let logDirectory: URL
    private let readinessDelay: TimeInterval
    /// Re-checked before every start, auto-restarts included; wired to
    /// ClaudeCLI in main.swift. Returns a failure reason or nil.
    var preflight: (() -> String?)?

    init(config: AppConfig, launcher: ProcessLaunching, logDirectory: URL,
         readinessDelay: TimeInterval = 5)
    {
        self.launcher = launcher
        self.logDirectory = logDirectory
        self.readinessDelay = readinessDelay
        setFolders(config.folders, claudePath: nil)
    }

    func setFolders(_ folders: [FolderConfig], claudePath: String?) {
        var existing = Dictionary(uniqueKeysWithValues: processes.map { ($0.folder.id, $0) })
        processes = folders.map { folder in
            if let p = existing.removeValue(forKey: folder.id) {
                p.update(folder: folder)
                if let claudePath { p.claudePath = claudePath }
                return p
            }
            let p = ServerProcess(
                folder: folder, launcher: launcher, logDirectory: logDirectory,
                claudePath: claudePath ?? "claude", readinessDelay: readinessDelay)
            p.onStateChange = { [weak self] _ in self?.onAnyStateChange?() }
            p.preflight = { [weak self] in self?.preflight?() }
            return p
        }
        // Removed folders: stop their servers.
        existing.values.forEach { $0.stop() }
    }

    func process(id: UUID) -> ServerProcess? {
        processes.first { $0.folder.id == id }
    }

    func start(id: UUID, claudePath: String?, loggedIn: Bool) {
        guard let p = process(id: id) else { return }
        start(p, claudePath: claudePath, loggedIn: loggedIn, manual: true)
    }

    private func start(_ p: ServerProcess, claudePath: String?, loggedIn: Bool, manual: Bool) {
        guard let claudePath else { p.setPreconditionFailure("claude not found"); return }
        guard loggedIn else { p.setPreconditionFailure("not logged in"); return }
        p.claudePath = claudePath
        p.start(manual: manual)
    }

    func autostart(claudePath: String?, loggedIn: Bool) {
        for p in processes where p.folder.autostart {
            start(p, claudePath: claudePath, loggedIn: loggedIn, manual: true)
        }
    }

    func startAll(claudePath: String?, loggedIn: Bool) {
        for p in processes where p.state.canStart {
            start(p, claudePath: claudePath, loggedIn: loggedIn, manual: true)
        }
    }

    func stopAll() {
        processes.forEach { $0.stop() }
    }

    /// Script + inner pids of managed servers, for the external-scan
    /// exclusion (the script command line matches the scan pattern too).
    func ownPids() -> Set<pid_t> {
        Set(processes.flatMap { $0.pids })
    }

    var states: [ServerState] { processes.map(\.state) }
    var anyActive: Bool { states.contains(where: \.isActive) }

    func killAllNow() {
        processes.forEach { $0.killNow() }
    }
}
```

(`ServerProcess.pids`, `innerPid`, and `setPreconditionFailure` already exist
from Task 10.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ServerManagerTests`
Expected: PASS (4 tests). Then run `swift test` — everything green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/ServerManager.swift Sources/ClaudeRCManager/ServerProcess.swift Tests/ClaudeRCManagerTests/ServerManagerTests.swift
git commit -m "Add server manager with autostart and bulk operations"
```

---

### Task 15: LoginItem wrapper

**Files:**
- Create: `Sources/ClaudeRCManager/LoginItem.swift`

Thin `SMAppService` wrapper; manual test only (registration talks to the OS).

- [ ] **Step 1: Implement**

`Sources/ClaudeRCManager/LoginItem.swift`:

```swift
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRCManager/LoginItem.swift
git commit -m "Add login-item wrapper"
```

---

### Task 16: SettingsWindow (SwiftUI form)

**Files:**
- Create: `Sources/ClaudeRCManager/SettingsWindow.swift`

Manual test layer. One window per folder; Save/Cancel; changes apply on next
start (spec: SettingsWindow).

- [ ] **Step 1: Implement**

`Sources/ClaudeRCManager/SettingsWindow.swift`:

```swift
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
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeRCManager/SettingsWindow.swift
git commit -m "Add per-folder settings window"
```

---

### Task 17: StatusMenuController + app wiring in main.swift

**Files:**
- Create: `Sources/ClaudeRCManager/StatusMenuController.swift`
- Modify: `Sources/ClaudeRCManager/main.swift`

Manual test layer. This is the largest UI task; everything it calls exists
from earlier tasks.

- [ ] **Step 1: Implement StatusMenuController**

`Sources/ClaudeRCManager/StatusMenuController.swift`:

```swift
import AppKit

/// NSStatusItem + menu, rebuilt on every open via menuNeedsUpdate (spec:
/// Menu structure). Icon updates on every state change, independent of the
/// menu being open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private let manager: ServerManager
    private let cli: ClaudeCLI
    private let store: ConfigStore
    private let settings = SettingsWindowController()
    private var config: AppConfig
    private var configWasCorrupt: Bool
    private var cachedLoggedIn = false
    private var externalServers: [ExternalServer] = []

    init(config: AppConfig, configWasCorrupt: Bool, manager: ServerManager,
         cli: ClaudeCLI, store: ConfigStore)
    {
        self.config = config
        self.configWasCorrupt = configWasCorrupt
        self.manager = manager
        self.cli = cli
        self.store = store
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        manager.onAnyStateChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    /// Called from main.swift once the launch-time resolution finishes, so
    /// the first menu open does not show stale "not logged in" state.
    func setLoggedIn(_ loggedIn: Bool) {
        cachedLoggedIn = loggedIn
        refreshIcon()
    }

    func refreshIcon() {
        let healthy = cachedLoggedIn && cli.binaryPath != nil && !configWasCorrupt
        let bucket = StatusIcon.bucket(states: manager.states, healthy: healthy)
        let image = NSImage(systemSymbolName: bucket.symbolName,
                            accessibilityDescription: "Claude RC Manager")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// Refreshes auth + external scan off the main thread; the results
    /// update the icon immediately and feed the NEXT menu open (an open
    /// NSMenu is not rebuilt mid-display).
    func refreshAuthAndExternal() {
        let ownPids = manager.ownPids()
        DispatchQueue.global().async { [weak self, cli] in
            _ = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            let external = ExternalServerScanner.scan(excluding: ownPids)
            DispatchQueue.main.async {
                self?.cachedLoggedIn = loggedIn
                self?.externalServers = external
                self?.refreshIcon()
            }
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAuthAndExternal()
        menu.removeAllItems()

        // Cached values only — no blocking CLI calls on the main thread.
        if cli.binaryPath == nil {
            menu.addItem(disabled("⚠️ claude CLI not found — install Claude Code"))
            menu.addItem(.separator())
        } else if !cachedLoggedIn {
            menu.addItem(disabled("⚠️ Claude not logged in"))
            let login = NSMenuItem(title: "Open login in Terminal…",
                                   action: #selector(openLogin), keyEquivalent: "")
            login.target = self
            menu.addItem(login)
            menu.addItem(.separator())
        }
        if configWasCorrupt {
            menu.addItem(disabled("⚠️ config.json was corrupt — moved to config.json.bak"))
            menu.addItem(.separator())
        }

        for process in manager.processes {
            menu.addItem(folderItem(for: process))
        }
        if !manager.processes.isEmpty { menu.addItem(.separator()) }

        if !externalServers.isEmpty {
            menu.addItem(disabled("External servers"))
            for server in externalServers {
                let name = (server.workingDirectory as NSString?)?.lastPathComponent
                    ?? "pid \(server.pid)"
                let item = disabled("\(name) — running (external)")
                item.toolTip = server.workingDirectory ?? server.command
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let add = NSMenuItem(title: "Add Folder…", action: #selector(addFolder), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let startAll = NSMenuItem(title: "Start All", action: #selector(startAllAction), keyEquivalent: "")
        startAll.target = self
        menu.addItem(startAll)
        let stopAll = NSMenuItem(title: "Stop All", action: #selector(stopAllAction), keyEquivalent: "")
        stopAll.target = self
        menu.addItem(stopAll)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Start at Login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        if !LoginItem.isAvailable {
            loginItem.action = nil
            loginItem.toolTip = "Install to /Applications first"
        }
        menu.addItem(loginItem)

        let quit = NSMenuItem(title: "Quit Claude RC Manager",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func statusLabel(_ state: ServerState) -> String {
        switch state {
        case .stopped: return "○ stopped"
        case .starting: return "◐ starting"
        case .running: return "● running"
        case .stopping: return "◐ stopping"
        case .restarting: return "◐ restarting…"
        case .ended: return "○ ended"
        case .failed(let reason): return "✕ failed (\(reason))"
        }
    }

    private func folderItem(for process: ServerProcess) -> NSMenuItem {
        let folder = process.folder
        let item = NSMenuItem(
            title: "\(folder.name)   \(statusLabel(process.state))",
            action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let toggle = NSMenuItem(
            title: process.state.isActive ? "Stop" : "Start",
            action: #selector(toggleServer(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = folder.id
        submenu.addItem(toggle)

        let log = NSMenuItem(title: "Open Log", action: #selector(openLog(_:)), keyEquivalent: "")
        log.target = self
        log.representedObject = folder.id
        submenu.addItem(log)

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.representedObject = folder.id
        submenu.addItem(settingsItem)

        let remove = NSMenuItem(title: "Remove…", action: #selector(removeFolder(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = folder.id
        submenu.addItem(remove)

        item.submenu = submenu
        return item
    }

    // MARK: Actions

    @objc private func openLogin() { cli.openLoginInTerminal() }

    @objc private func toggleServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        if process.state.isActive {
            process.stop()
        } else {
            // Resolve + auth off the main thread, then start on main.
            DispatchQueue.global().async { [weak self, cli] in
                let path = cli.resolveBinary()
                let loggedIn = cli.isLoggedIn()
                DispatchQueue.main.async {
                    self?.cachedLoggedIn = loggedIn
                    self?.manager.start(id: id, claudePath: path, loggedIn: loggedIn)
                }
            }
        }
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        NSWorkspace.shared.open(process.logURL)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        settings.show(folder: process.folder) { [weak self] updated in
            self?.replaceFolder(updated)
        }
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let process = manager.process(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(process.folder.name)”?"
        alert.informativeText = "The server is stopped and the folder removed from the list. The log file is kept."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        process.stop()
        config.folders.removeAll { $0.id == id }
        persist()
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        guard !config.folders.contains(where: { $0.path == path }) else {
            let alert = NSAlert()
            alert.messageText = "Folder already added"
            alert.informativeText = path
            alert.runModal()
            return
        }
        let folder = FolderConfig(path: path)
        config.folders.append(folder)
        persist()
        settings.show(folder: folder) { [weak self] updated in
            self?.replaceFolder(updated)
        }
    }

    @objc private func startAllAction() {
        DispatchQueue.global().async { [weak self, cli] in
            let path = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            DispatchQueue.main.async {
                self?.cachedLoggedIn = loggedIn
                self?.manager.startAll(claudePath: path, loggedIn: loggedIn)
            }
        }
    }

    @objc private func stopAllAction() { manager.stopAll() }

    @objc private func toggleLoginItem() {
        if let message = LoginItem.toggle() {
            let alert = NSAlert()
            alert.messageText = "Could not change login item"
            alert.informativeText = message
            alert.runModal()
        }
    }

    private func replaceFolder(_ updated: FolderConfig) {
        guard let index = config.folders.firstIndex(where: { $0.id == updated.id }) else { return }
        config.folders[index] = updated
        persist()
    }

    private func persist() {
        try? store.save(config)
        manager.setFolders(config.folders, claudePath: cli.binaryPath)
    }
}
```

- [ ] **Step 2: Wire everything in main.swift**

Replace `Sources/ClaudeRCManager/main.swift`:

```swift
import AppKit

// NOT @MainActor on the class: top-level code in main.swift is nonisolated,
// so a @MainActor init would not compile (verified by probe). The
// NSApplicationDelegate callbacks are main-actor anyway.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuController: StatusMenuController?
    var manager: ServerManager?
    let cli = ClaudeCLI()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance (spec: Process lifecycle). Bundle id exists only
        // in the .app bundle; skip the check for bare-binary dev runs.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1
        {
            NSApp.terminate(nil)
            return
        }

        let store = ConfigStore()
        let loaded = store.load()
        let config: AppConfig
        let wasCorrupt: Bool
        switch loaded {
        case .fresh(let c): config = c; wasCorrupt = false
        case .recoveredFromCorrupt(let c): config = c; wasCorrupt = true
        }

        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ClaudeRCManager")
        let manager = ServerManager(
            config: config, launcher: ScriptLauncher(), logDirectory: logDir)
        self.manager = manager
        // Preflight re-checks preconditions on every start, restarts
        // included. isLoggedIn() is cached for 60 s.
        manager.preflight = { [cli] in
            guard cli.binaryPath != nil else { return "claude not found" }
            return cli.isLoggedIn() ? nil : "not logged in"
        }
        menuController = StatusMenuController(
            config: config, configWasCorrupt: wasCorrupt,
            manager: manager, cli: cli, store: store)

        DispatchQueue.global().async { [cli] in
            let path = cli.resolveBinary()
            let loggedIn = cli.isLoggedIn()
            DispatchQueue.main.async { [weak self] in
                self?.menuController?.setLoggedIn(loggedIn)
                self?.manager?.setFolders(config.folders, claudePath: path)
                self?.manager?.autostart(claudePath: path, loggedIn: loggedIn)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager, manager.anyActive else { return .terminateNow }
        manager.stopAll()
        // Shared 5 s deadline, then SIGKILL stragglers (spec: quit).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            manager.killAllNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

if NSClassFromString("XCTestCase") == nil {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
```

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build && swift test`
Expected: builds clean, all tests pass.

- [ ] **Step 4: Manual smoke test**

Run: `swift run` (Ctrl-C to quit afterwards)
Expected: a terminal-symbol icon appears in the menu bar; the menu shows
Add Folder…, Start All/Stop All, Start at Login (disabled outside
/Applications), Quit. Add a folder, start it, check
`~/Library/Logs/ClaudeRCManager/<uuid>.log` fills. **Do not verify further UI
behavior yourself — Sven drives the app** (memory: Sven launches the app
himself; report what to check instead).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeRCManager/StatusMenuController.swift Sources/ClaudeRCManager/main.swift
git commit -m "Add status menu and app wiring"
```

---

### Task 18: Makefile + Info.plist + app bundle

**Files:**
- Create: `Resources/Info.plist`
- Create: `Makefile`

- [ ] **Step 1: Write Info.plist**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Claude RC Manager</string>
    <key>CFBundleDisplayName</key>
    <string>Claude RC Manager</string>
    <key>CFBundleIdentifier</key>
    <string>com.sveneisenschmidt.claude-rc-manager</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeRCManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Write Makefile**

`Makefile` (recipe lines are TABs, not spaces):

```makefile
APP_NAME = Claude RC Manager
BUILD_DIR = .build/release
APP_DIR = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build test app install clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp "$(BUILD_DIR)/ClaudeRCManager" "$(APP_DIR)/Contents/MacOS/ClaudeRCManager"
	codesign --force --sign - "$(APP_DIR)"
	@echo "Built: $(APP_DIR)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf .build
```

- [ ] **Step 3: Verify**

Run: `make app`
Expected: prints `Built: .build/release/Claude RC Manager.app`;
`codesign -dv ".build/release/Claude RC Manager.app"` shows `Signature=adhoc`.

- [ ] **Step 4: Commit**

```bash
git add Resources/Info.plist Makefile
git commit -m "Add app bundle build and install targets"
```

---

### Task 19: README + LICENSE

**Files:**
- Create: `README.md`
- Create: `LICENSE`

- [ ] **Step 1: Write README.md**

```markdown
# Claude RC Manager

A macOS menu-bar app that runs one [`claude remote-control`](https://docs.claude.com/en/docs/claude-code/remote-control)
server per configured folder, so you can start Claude Code sessions on your
Mac from the Claude mobile app or claude.ai/code.

Servers run in standby by default (`--no-create-session-in-dir`): the server
holds the folder open, and new sessions are created on demand from your
phone. Spawn mode (`same-dir`, `worktree`, `session`), capacity, permission
mode, and extra CLI arguments are configurable per folder, plus autostart
and crash auto-restart with backoff.

## Requirements

- macOS 13+
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and
  logged in with a subscription (`claude auth login`)
- Workspace trust accepted once per folder: run `claude` in the folder once
- Worktree spawn mode needs the folder to be a git repository (or
  WorktreeCreate/WorktreeRemove hooks)

## Install

```bash
make install
```

builds the app (ad-hoc signed) and copies it to `/Applications`. Start it
from there; enable "Start at Login" in the menu if you want it persistent.

Note: the ad-hoc code signature changes on every rebuild, so after a
reinstall macOS may ask you to re-approve the login item in
System Settings → General → Login Items.

## Usage

Click the terminal icon in the menu bar:

- **Add Folder…** — pick a project folder; a settings window opens.
- Per folder: **Start/Stop**, **Open Log**, **Settings…**, **Remove…**.
- **External servers** — remote-control processes started outside the app
  are listed read-only.
- Logs live in `~/Library/Logs/ClaudeRCManager/`.

## Limitations

- Force-quitting the app leaves servers running (regular quit stops them).
- Downloaded release builds are not notarized; macOS will block the first
  launch. Either build from source (`make install`) or clear the quarantine
  flag: `xattr -d com.apple.quarantine "/Applications/Claude RC Manager.app"`.
  Developer-ID signing + notarization is a planned follow-up.

## Development

```bash
swift test   # unit tests
swift run    # run from the checkout (menu bar icon, no Dock icon)
make app     # build the .app bundle
```
```

- [ ] **Step 2: Write LICENSE**

MIT license, copyright line:

```
MIT License

Copyright (c) 2026 Sven Eisenschmidt
```

(Use the standard MIT text body from https://opensource.org/license/mit —
the full text, not a link, in the file.)

- [ ] **Step 3: Commit**

```bash
git add README.md LICENSE
git commit -m "Add README and MIT license"
```

---

### Task 20: GitHub Actions workflows

**Files:**
- Create: `.github/workflows/build.yml`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write build.yml**

```yaml
name: Build

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

- [ ] **Step 2: Write release.yml**

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Test
        run: swift test
      - name: Build app
        run: make app
      - name: Zip
        run: |
          cd .build/release
          ditto -c -k --keepParent "Claude RC Manager.app" "ClaudeRCManager-${GITHUB_REF_NAME}.zip"
      - name: Create release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            ".build/release/ClaudeRCManager-${GITHUB_REF_NAME}.zip" \
            --title "Claude RC Manager $GITHUB_REF_NAME" \
            --generate-notes
```

- [ ] **Step 3: Validate YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); yaml.safe_load(open('.github/workflows/release.yml')); print('ok')"`
Expected: `ok` (if PyYAML is missing, `ruby -ryaml -e "YAML.load_file('.github/workflows/build.yml'); YAML.load_file('.github/workflows/release.yml'); puts 'ok'"`)

- [ ] **Step 4: Commit**

```bash
git add .github
git commit -m "Add CI build and tag-release workflows"
```

---

### Task 21: Final verification

- [ ] **Step 1: Full suite + bundle**

Run: `swift test && make app`
Expected: all tests pass, bundle builds.

- [ ] **Step 2: Hand off to Sven for manual testing**

Report to Sven what to verify (he drives the app):
1. `make install`, launch from /Applications.
2. Add a real project folder; server starts; phone sees it.
3. Stop from menu; process actually gone (`pgrep -fl remote-control`).
4. Quit app; all servers gone.
5. Start at Login toggle.
6. External server: start `claude remote-control` in a terminal; it shows up
   in the menu as external.

Do NOT tag a release before Sven confirms.
