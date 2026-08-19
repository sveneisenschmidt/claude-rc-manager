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
