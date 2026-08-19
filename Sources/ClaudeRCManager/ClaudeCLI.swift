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
                Darwin.kill(p.processIdentifier, SIGKILL)
            }
            readHandle.readabilityHandler = nil
            try? readHandle.close()
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

    @discardableResult
    func resolveBinary() -> String? {
        if let cached = binaryPath { return cached }
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
        binaryPath = path
        return path
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
        // The user is about to authenticate interactively; the next check
        // must hit the CLI instead of returning a stale cached verdict.
        lastAuth = nil
    }
}
