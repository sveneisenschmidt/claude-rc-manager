import Foundation

/// Finds the claude binary and checks login state (spec: ClaudeCLI).
/// GUI apps inherit no shell PATH, so resolution runs a login shell once;
/// re-resolves on demand while unresolved. Auth result is cached for 60 s.
/// `binaryPath`/`lastAuth` are guarded by `stateLock`; the lock is never
/// held while a subprocess call is in flight, so a 5 s auth check never
/// blocks a `binaryPath` read from another thread.
final class ClaudeCLI: @unchecked Sendable {
    private let stateLock = NSLock()
    private var _binaryPath: String?
    private var _lastAuth: (loggedIn: Bool, at: Date)?

    private(set) var binaryPath: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _binaryPath }
        set { stateLock.lock(); _binaryPath = newValue; stateLock.unlock() }
    }

    private var lastAuth: (loggedIn: Bool, at: Date)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastAuth }
        set { stateLock.lock(); _lastAuth = newValue; stateLock.unlock() }
    }

    /// Runs a command with a timeout; returns stdout or nil on any failure.
    /// stdout is drained via a `readabilityHandler` installed on the pipe
    /// before the process starts, not by a blocking read after exit, so a
    /// child that writes more than the pipe buffer (~64 KB) cannot deadlock
    /// this call — the handler keeps draining while the poll loop runs
    /// below and holds no thread while idle between chunks. On timeout the
    /// child is escalated from SIGTERM to SIGKILL rather than merely
    /// abandoned, so an unresponsive child cannot leak past the timeout.
    static func run(_ argv: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        let readHandle = out.fileHandleForReading
        let lock = NSLock()
        var buffer = Data()
        var reachedEOF = false
        let eofGroup = DispatchGroup()
        eofGroup.enter()

        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if data.isEmpty {
                if !reachedEOF {
                    reachedEOF = true
                    lock.unlock()
                    handle.readabilityHandler = nil
                    eofGroup.leave()
                    return
                }
                lock.unlock()
                return
            }
            buffer.append(data)
            lock.unlock()
        }

        do {
            try p.run()
        } catch {
            readHandle.readabilityHandler = nil
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            p.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while p.isRunning && Date() < killDeadline {
                usleep(50_000)
            }
            if p.isRunning {
                // Microsecond TOCTOU vs pid recycling is accepted here: the
                // pid was checked via isRunning just above, and this is a
                // short-lived helper we spawned ourselves — unlike the
                // long-lived inner server pid, which ProcessLauncher protects
                // with a start-time identity check.
                Darwin.kill(p.processIdentifier, SIGKILL)
            }
            // No explicit close(): clearing the handler cancels the dispatch
            // source, and Pipe closes the fd on dealloc. An explicit close
            // could race an in-flight handler's availableData (EBADF raises
            // an uncatchable ObjC exception).
            readHandle.readabilityHandler = nil
            return nil
        }

        // Normal exit: wait briefly for the handler to observe EOF.
        _ = eofGroup.wait(timeout: .now() + 2)
        readHandle.readabilityHandler = nil
        lock.lock()
        let data = buffer
        lock.unlock()
        return p.terminationStatus == 0 ? data : nil
    }

    /// Install locations to try when the login shell finds nothing. A GUI
    /// app's login shell reads .zprofile but not .zshrc — a PATH entry that
    /// lives only in .zshrc (the common setup) is invisible here, so the
    /// shell lookup alone reports "claude not found" for a working install.
    static func knownLocations(home: String) -> [String] {
        [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    @discardableResult
    func resolveBinary() -> String? {
        if let cached = binaryPath { return cached }
        if let path = shellLookup() ?? knownLocationLookup() {
            binaryPath = path
            return path
        }
        return nil
    }

    private func shellLookup() -> String? {
        guard let data = ClaudeCLI.run(
            ["/bin/zsh", "-lc", "command -v claude"], timeout: 10),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        // A login shell may print startup banners before the actual
        // `command -v` output, so take the last non-empty line.
        let path = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard let path, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    private func knownLocationLookup() -> String? {
        ClaudeCLI.knownLocations(home: NSHomeDirectory())
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The cached auth verdict, or nil when nothing is cached or the cache
    /// has expired. Never runs a subprocess, so it is safe on the main
    /// thread — unlike `isLoggedIn()`, which can busy-poll for seconds.
    var cachedLoggedIn: Bool? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let last = _lastAuth, Date().timeIntervalSince(last.at) < 60 else { return nil }
        return last.loggedIn
    }

    /// Warms the auth cache off the main thread. Fire-and-forget: callers
    /// that must not block (preflight, menu build) read `cachedLoggedIn`
    /// and use this to make the *next* read accurate.
    func refreshAuthInBackground() {
        DispatchQueue.global().async { [self] in
            _ = isLoggedIn()
        }
    }

    /// Cached for 60 s (spec: Login check). Call off the main thread.
    func isLoggedIn(force: Bool = false) -> Bool {
        if !force, let last = lastAuth, Date().timeIntervalSince(last.at) < 60 {
            return last.loggedIn
        }
        guard let claude = resolveBinary() else {
            // Binary not found: do not cache. A later launch attempt should
            // re-resolve immediately rather than being held back by a
            // stale "logged out" verdict from a transient PATH problem.
            return false
        }
        guard let data = ClaudeCLI.run([claude, "auth", "status"], timeout: 5) else {
            lastAuth = (false, Date())
            return false
        }
        let result = AuthStatus.isLoggedIn(data)
        lastAuth = (result, Date())
        return result
    }

    /// Opens Terminal running `claude auth login` (interactive OAuth).
    /// Returns false when osascript failed — the automation permission
    /// (NSAppleEventsUsageDescription prompt) was denied, or Terminal
    /// could not be scripted — so the caller can tell the user instead of
    /// failing silently. Blocking (waits for osascript); call off main.
    @discardableResult
    func openLoginInTerminal() -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "claude auth login"
        end tell
        """
        // The user is about to authenticate interactively; the next check
        // must hit the CLI instead of returning a stale cached verdict.
        lastAuth = nil
        return ClaudeCLI.run(["/usr/bin/osascript", "-e", script], timeout: 15) != nil
    }
}
