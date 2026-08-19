import Darwin
import Foundation

/// One running server's process handle, as seen by ServerProcess.
/// The output and exit callbacks are supplied at launch time (see
/// `ProcessLaunching`), so no output can be produced before they are wired up.
protocol RunningServer: AnyObject {
    /// pid of the inner claude process (script's child), once resolved.
    var innerPid: pid_t? { get }
    /// All pids of this server's tree (script + inner child), for the
    /// external-scan exclusion.
    var pids: [pid_t] { get }
    /// SIGTERM to the inner process group; SIGKILL after `gracePeriod`.
    func stop(gracePeriod: TimeInterval)
    /// Immediate SIGKILL to everything (quit deadline).
    func kill()
}

protocol ProcessLaunching {
    /// `onOutput` is called with raw pty chunks on a reader thread; `onExit`
    /// once with script's status when the process tree exits. Both are
    /// installed before the process starts and cross threads (@Sendable).
    func launch(argv: [String], workingDirectory: String,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningServer
}

/// Real launcher: runs `script -q /dev/null ...`. Verified reality (spec:
/// Command and process tree): script's child sits in its OWN session and
/// process group, so signals must target the inner pid, which we resolve
/// via pgrep -P. stdin is /dev/null (script fails on socket stdin).
final class ScriptLauncher: ProcessLaunching {
    /// @unchecked: mutable state is lock-protected or queue-confined.
    final class Server: RunningServer, @unchecked Sendable {
        let process = Process()
        private let queue = DispatchQueue(label: "server-process")
        private let lock = NSLock()
        private var _innerPid: pid_t?
        /// Start time of `_innerPid`, to detect pid recycling before signaling.
        private var _innerStart: UInt64?
        /// Queue-confined: keeps repeated stop() calls from stacking timers.
        private var stopScheduled = false

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
            let start = Self.startTime(of: pid)
            lock.lock(); _innerPid = pid; _innerStart = start; lock.unlock()
        }

        /// Process start time in microseconds, the identity half of a pid:
        /// pids are reused, start times effectively are not.
        static func startTime(of pid: pid_t) -> UInt64? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        }

        /// Signals the inner process group — but only if the pid still refers
        /// to the process we resolved. Between resolution and signaling the
        /// inner process can exit and its pid be reused, and killpg against a
        /// stranger's process group cannot be taken back.
        ///
        /// When no start time was recorded (proc_pidinfo failed at resolve
        /// time), script's liveness is the identity proof: while script is
        /// alive, its child or its unreaped zombie still owns that pid, so
        /// recycling is impossible. Refusing to signal in that case would
        /// silently orphan a TERM-trapping inner claude.
        private func signalInnerGroup(_ signal: Int32) {
            lock.lock()
            let pid = _innerPid
            let recorded = _innerStart
            lock.unlock()
            guard let pid else { return }
            if let recorded {
                guard let current = Self.startTime(of: pid), current == recorded else { return }
            } else if !process.isRunning {
                return  // no identity proof and script is gone: refuse to guess
            }
            killpg(pid, signal)
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
            guard (try? p.run()) != nil else { return nil }
            // Read before waiting: a full pipe buffer would deadlock the child.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").first else { return nil }
            return pid_t(line.trimmingCharacters(in: .whitespaces))
        }

        func stop(gracePeriod: TimeInterval) {
            queue.async { [weak self] in
                guard let self, !self.stopScheduled else { return }
                self.stopScheduled = true
                // Wait for the inner pid if it has not resolved yet —
                // signaling only script would orphan the inner claude.
                if self.resolveInnerPidBlocking() != nil {
                    // Inner pid is its own group leader (login_tty session).
                    self.signalInnerGroup(SIGTERM)
                }
                if self.process.isRunning { self.process.terminate() }
                // Grace period runs from the moment TERM was actually sent,
                // not from the stop() call: resolving the pid can take a while.
                self.queue.asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
                    guard let self else { return }
                    // script exits as soon as its child detaches, so its
                    // liveness says nothing about the inner claude: escalate
                    // on the inner pid, which a TERM-trapping child keeps
                    // alive past the grace period. signalInnerGroup carries
                    // its own existence/identity check.
                    self.signalInnerGroup(SIGKILL)
                    if self.process.isRunning { self.kill() }
                }
            }
        }

        func kill() {
            signalInnerGroup(SIGKILL)
            if process.isRunning {
                // script is not a group leader; signal the pid directly.
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func launch(argv: [String], workingDirectory: String,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningServer
    {
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
        // Handlers are installed before run(): a process that fails instantly
        // would otherwise have its first chunk (the error message) dropped.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil  // EOF
                return
            }
            onOutput(data)
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            onExit(proc.terminationStatus)
        }
        try p.run()
        server.resolveInnerPid()
        return server
    }
}
