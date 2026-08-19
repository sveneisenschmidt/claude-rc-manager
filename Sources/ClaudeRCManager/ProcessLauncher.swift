import Darwin
import Foundation

/// One running server's process handle, as seen by ServerProcess.
/// The output and exit callbacks are supplied at launch time (see
/// `ProcessLaunching`), so no output can be produced before they are wired up.
protocol RunningServer: AnyObject {
    /// pid of the claude process. Known at spawn time (we spawn it directly).
    var innerPid: pid_t? { get }
    /// All pids of this server, for the external-scan exclusion.
    var pids: [pid_t] { get }
    /// SIGTERM to the process group; SIGKILL after `gracePeriod`.
    func stop(gracePeriod: TimeInterval)
    /// Immediate SIGKILL to everything (quit deadline).
    func kill()
}

protocol ProcessLaunching {
    /// `onOutput` is called with raw pty chunks on a reader thread; `onExit`
    /// once with the child's status when it exits. Both are installed before
    /// the process starts and cross threads (@Sendable).
    func launch(argv: [String], workingDirectory: String,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningServer
}

enum LaunchError: Error {
    case ptyUnavailable(Int32)
    case spawnFailed(Int32)
}

/// Real launcher: spawns the CLI on a pty this process owns (spec: Command and
/// process tree, amended 2026-08-19).
///
/// Verified on this machine: `script -q /dev/null` with stdin `/dev/null`
/// forwards the stdin EOF into the pty as Ctrl-D, and `claude remote-control`
/// exits seconds after becoming ready — every server died and the app
/// crash-looped. With a pty we own, the parent holds the master open forever
/// and never writes to it, so the CLI never sees EOF and stays up.
///
/// The child is spawned with POSIX_SPAWN_SETSID, so it is its own session and
/// process group leader: `killpg(pid, …)` reaches it and its descendants and
/// can never travel up into this app.
final class PtyLauncher: ProcessLaunching {
    /// @unchecked: mutable state is lock-protected or queue-confined.
    final class Server: RunningServer, @unchecked Sendable {
        private let pid: pid_t
        /// Start time of `pid`, to detect pid recycling before signaling.
        private let startedAt: UInt64?
        /// The pty master. Held open for the server's whole life — closing it
        /// (or writing to it) is what would kill the CLI. Never written to.
        private let master: FileHandle
        private let onOutput: @Sendable (Data) -> Void
        private let onExit: @Sendable (Int32) -> Void
        private let queue = DispatchQueue(label: "server-process")
        private let lock = NSLock()
        /// Lock-protected: set inside the same critical section that reaps the
        /// child, so a signal can never race a reap and hit a recycled pid.
        private var reaped = false
        /// Queue-confined: keeps repeated stop() calls from stacking timers.
        private var stopScheduled = false
        /// Queue-confined.
        private var exitSource: DispatchSourceProcess?

        var innerPid: pid_t? { pid }
        var pids: [pid_t] { [pid] }

        init(pid: pid_t, master: Int32,
             onOutput: @escaping @Sendable (Data) -> Void,
             onExit: @escaping @Sendable (Int32) -> Void)
        {
            self.pid = pid
            self.startedAt = Self.startTime(of: pid)
            self.master = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            self.onOutput = onOutput
            self.onExit = onExit
        }

        /// Process start time in microseconds, the identity half of a pid:
        /// pids are reused, start times effectively are not.
        static func startTime(of pid: pid_t) -> UInt64? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        }

        /// Reader + exit watch. Installed before the caller can see the server,
        /// so a process that dies instantly still reports its output and exit.
        fileprivate func start() {
            let output = onOutput
            master.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil  // EOF
                    return
                }
                output(data)
            }
            let source = DispatchSource.makeProcessSource(
                identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.handleExit(probe: false) }
            exitSource = source
            source.activate()
            // The child can die before the source is activated; kqueue-based
            // process sources do not reliably report an exit that already
            // happened. One WNOHANG probe closes that window (the child is
            // never reaped anywhere else, so its zombie is still there).
            queue.async { [weak self] in self?.handleExit(probe: true) }
        }

        /// Reaps the child and reports the exit exactly once.
        private func handleExit(probe: Bool) {  // queue-confined
            lock.lock()
            if reaped { lock.unlock(); return }
            var status: Int32 = 0
            let result = waitpid(pid, &status, probe ? WNOHANG : 0)
            if probe && result == 0 { lock.unlock(); return }  // still running
            reaped = true
            lock.unlock()

            exitSource?.cancel()
            exitSource = nil
            drain()
            master.readabilityHandler = nil
            onExit(result == pid ? Self.exitCode(from: status) : -1)
        }

        /// Non-blocking read of whatever the pty still holds. The pty discards
        /// buffered output once the last slave fd closes, so the tail of a
        /// short-lived child can otherwise be lost between its exit and the
        /// reader's next wakeup. Non-blocking on purpose: a descendant may keep
        /// the slave open, in which case there is no EOF to wait for.
        private func drain() {
            let fd = master.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { return }  // EOF, EAGAIN or error
                onOutput(Data(buffer[0..<n]))
            }
        }

        /// Exit status in the wording ServerProcess shows: the exit code for a
        /// normal exit, the raw signal number for a signal death.
        static func exitCode(from status: Int32) -> Int32 {
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : signal
        }

        /// Signals the child's process group — but only while we still hold
        /// its identity. Until the child is reaped its pid cannot be recycled
        /// (the zombie owns it), and the reap happens under the same lock, so
        /// killpg can never land on a stranger's group. The start-time check is
        /// the belt to that suspenders.
        private func signalGroup(_ signal: Int32) {
            lock.lock()
            defer { lock.unlock() }
            guard !reaped else { return }
            if let startedAt, let current = Self.startTime(of: pid), current != startedAt {
                return
            }
            killpg(pid, signal)
        }

        func stop(gracePeriod: TimeInterval) {
            queue.async { [weak self] in
                guard let self, !self.stopScheduled else { return }
                self.stopScheduled = true
                self.signalGroup(SIGTERM)
                // Strong on purpose: the escalation must outlive the owner —
                // when the ServerProcess holding this server is released
                // mid-grace-period (folder removed), a weak capture would drop
                // the SIGKILL and orphan the CLI, which ignores TERM entirely.
                // Bounded by gracePeriod, so the extra retain is short-lived.
                self.queue.asyncAfter(deadline: .now() + gracePeriod) {
                    self.signalGroup(SIGKILL)
                }
            }
        }

        func kill() {
            signalGroup(SIGKILL)
        }
    }

    func launch(argv: [String], workingDirectory: String,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningServer
    {
        precondition(!argv.isEmpty)
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw LaunchError.ptyUnavailable(errno)
        }
        // A zero window size makes some TUIs render nothing at all.
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Own session (and process group): killpg against the child can never
        // travel up into this app, and the CLI gets the fresh session it wants.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var arguments = Self.cStrings(argv)
        var environment = Self.cStrings(Self.childEnvironment())
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &actions, &attributes,
                                 &arguments, &environment)
        // The parent must not keep a slave fd: it would hold the pty open past
        // the child's death and no EOF would ever reach the reader.
        close(slave)
        guard result == 0 else {
            close(master)
            throw LaunchError.spawnFailed(result)
        }

        let server = Server(pid: pid, master: master,
                            onOutput: onOutput, onExit: onExit)
        server.start()
        return server
    }

    /// The app's environment plus a TERM the CLI can render into, if the app
    /// was launched without one (Finder/launchd give none).
    private static func childEnvironment() -> [String] {
        var result: [String] = []
        var entry = environ
        while let value = entry.pointee {
            result.append(String(cString: value))
            entry += 1
        }
        if !result.contains(where: { $0.hasPrefix("TERM=") }) {
            result.append("TERM=xterm-256color")
        }
        return result
    }

    /// NULL-terminated argv/envp; the caller frees the copies.
    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        result.append(nil)
        return result
    }
}
