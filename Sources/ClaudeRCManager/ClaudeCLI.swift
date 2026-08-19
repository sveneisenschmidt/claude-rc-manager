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

        // Drain stdout on a background thread, started before the poll loop.
        // A child that writes more than the pipe buffer (~64 KB) blocks on
        // write() until someone reads; reading only after the loop (i.e.
        // after waitUntilExit-style polling) would deadlock against that
        // write. Read concurrently and join the reader once the process
        // has exited.
        let lock = NSLock()
        var outputData: Data?
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global().async {
            let data = try? out.fileHandleForReading.readToEnd()
            lock.lock()
            outputData = data
            lock.unlock()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        // The reader finishes once the pipe's write end closes, which
        // happens at (or just after) process exit.
        _ = readGroup.wait(timeout: .now() + 5)
        lock.lock()
        let data = outputData
        lock.unlock()
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
