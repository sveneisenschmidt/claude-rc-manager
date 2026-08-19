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
    case spawnSetupFailed(Int32)
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
///
/// Note what SETSID does *not* do: the child gets a new session but **no
/// controlling terminal** (no `TIOCSCTTY`). `isatty()` on its stdio is true and
/// terminal ioctls work, but `/dev/tty` cannot be opened, job control has no
/// terminal to arbitrate, and closing the master delivers **no SIGHUP** — a
/// child only notices via EOF on read / EIO on write. Stopping a server
/// therefore never relies on the pty closing; it signals the process group.
final class PtyLauncher: ProcessLaunching {
    /// @unchecked: mutable state is lock-protected or queue-confined.
    final class Server: RunningServer, @unchecked Sendable {
        private let pid: pid_t
        /// Start time of `pid`, to detect pid recycling before signaling.
        private let startedAt: UInt64?
        /// The pty master, non-blocking. Held open for the server's whole life
        /// — closing it (or writing to it) is what would kill the CLI. Never
        /// written to. Closed by the read source's cancel handler, the one
        /// place that may close it while a dispatch source watches it.
        private let master: Int32
        private let onOutput: @Sendable (Data) -> Void
        private let onExit: @Sendable (Int32) -> Void
        private let queue = DispatchQueue(label: "server-process")
        private let lock = NSLock()
        /// Lock-protected: set inside the same critical section that reaps the
        /// child, so a signal can never race a reap and hit a recycled pid.
        private var reaped = false
        /// Queue-confined: keeps repeated stop() calls from stacking timers.
        private var stopScheduled = false
        /// Queue-confined. Both hold `self` strongly on purpose (see `start()`).
        private var exitSource: DispatchSourceProcess?
        private var readSource: DispatchSourceRead?

        var innerPid: pid_t? { pid }
        var pids: [pid_t] { [pid] }

        init(pid: pid_t, master: Int32,
             onOutput: @escaping @Sendable (Data) -> Void,
             onExit: @escaping @Sendable (Int32) -> Void)
        {
            self.pid = pid
            self.startedAt = Self.startTime(of: pid)
            self.master = master
            self.onOutput = onOutput
            self.onExit = onExit
        }

        /// Backstop for a server that is released without ever having reported
        /// an exit (only reachable if `start()` never ran): leaving the child
        /// unreaped would strand a zombie for the app's lifetime.
        deinit {
            if !reaped {
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
            }
        }

        /// Process start time in microseconds, the identity half of a pid:
        /// pids are reused, start times effectively are not.
        static func startTime(of pid: pid_t) -> UInt64? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        }

        /// Reader + exit watch, both confined to `queue` (so a read never races
        /// the exit path over the same fd). Installed before the caller can see
        /// the server, so a process that dies instantly still reports its
        /// output and exit.
        ///
        /// Both event handlers capture `self` **strongly**: an owner that drops
        /// the server (folder removed mid-run) must not silently cancel the
        /// reap — the child would keep running with nobody left to signal or
        /// report it. The cycle is broken in `handleExit`, which cancels and
        /// releases both sources; a live dispatch source must outlive its fd
        /// and may not be released while still active, so the retain is what
        /// keeps that legal.
        fileprivate func start() {
            let reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            reader.setEventHandler { [self] in readAvailable() }
            // The one place that closes the master: dispatch guarantees the
            // cancel handler runs after the last event handler, so no read can
            // land on a closed (or recycled) descriptor.
            reader.setCancelHandler { [master] in close(master) }
            readSource = reader
            reader.activate()

            let exit = DispatchSource.makeProcessSource(
                identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [self] in handleExit(probe: false) }
            exitSource = exit
            exit.activate()
            // The child can die before the source is activated; kqueue-based
            // process sources do not reliably report an exit that already
            // happened. One WNOHANG probe closes that window (the child is
            // never reaped anywhere else, so its zombie is still there).
            queue.async { [weak self] in self?.handleExit(probe: true) }
        }

        /// One pty read per readable event. Raw `read(2)` on a non-blocking fd:
        /// FileHandle.availableData would raise an uncatchable ObjC exception
        /// on a non-blocking descriptor that has nothing to give.
        private func readAvailable() {  // queue-confined
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if n > 0 {
                onOutput(Data(buffer[0..<n]))
                return
            }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            // EOF (last slave fd gone) or a hard error: nothing more will ever
            // arrive, and an armed source would spin on it. The exit source
            // still reports the exit.
            readSource?.cancel()
            readSource = nil
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
            // Cancel first: the cancel handler (which closes the fd) is queued
            // behind this work item, so the drain below still owns the fd.
            // If the reader cancelled itself earlier (EOF), the fd may already
            // be closed — and a closed fd number can be recycled, so reading it
            // could steal another server's output. Drain only what we own.
            let ownsMaster = readSource != nil
            readSource?.cancel()
            readSource = nil
            if ownsMaster { drain() }
            onExit(result == pid ? Self.exitCode(from: status) : -1)
        }

        /// Non-blocking read of whatever the pty still holds. The pty discards
        /// buffered output once the last slave fd closes, so the tail of a
        /// short-lived child can otherwise be lost between its exit and the
        /// reader's next wakeup. Bounded: a descendant may keep the slave open
        /// and keep writing, and the exit report must not wait for it.
        private func drain() {  // queue-confined
            var buffer = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<16 {  // at most 1 MiB
                let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
                if n > 0 {
                    onOutput(Data(buffer[0..<n]))
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                return  // EOF, EAGAIN or error
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

        /// Strong `self` in both blocks on purpose: a stop must outlive its
        /// owner. When the ServerProcess holding this server is released right
        /// after stop() (folder removed), a weak capture drops the whole
        /// sequence — no TERM, no KILL — and orphans a CLI that ignores TERM
        /// anyway. Both retains are bounded by `gracePeriod`.
        func stop(gracePeriod: TimeInterval) {
            queue.async { [self] in
                guard !stopScheduled else { return }
                stopScheduled = true
                signalGroup(SIGTERM)
                queue.asyncAfter(deadline: .now() + gracePeriod) { [self] in
                    signalGroup(SIGKILL)
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
        // The reader uses raw read(2) and must never block on a spurious
        // wakeup; the exit path drains the same fd without blocking either.
        if let flags = nonNegative(fcntl(master, F_GETFL)) {
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        }
        // Belt to POSIX_SPAWN_CLOEXEC_DEFAULT below: no other launch (or any
        // Foundation Process elsewhere in the app) may leak this pty into its
        // child, or that child would hold this server's pty open forever.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        // A zero window size makes some TUIs render nothing at all.
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var ownsMaster = true
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            // The parent must not keep a slave fd: it would hold the pty open
            // past the child's death and no EOF would ever reach the reader.
            close(slave)
            if ownsMaster { close(master) }
        }

        try check(posix_spawn_file_actions_init(&actions))
        // dup2 targets survive POSIX_SPAWN_CLOEXEC_DEFAULT; everything else in
        // this process (other servers' masters included) does not.
        try check(posix_spawn_file_actions_adddup2(&actions, slave, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, slave, 1))
        try check(posix_spawn_file_actions_adddup2(&actions, slave, 2))
        if slave > 2 {
            try check(posix_spawn_file_actions_addclose(&actions, slave))
        }
        if master > 2 {
            try check(posix_spawn_file_actions_addclose(&actions, master))
        }
        try check(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory))

        try check(posix_spawnattr_init(&attributes))
        // SETSID: own session and process group, so killpg against the child
        // can never travel up into this app, and the CLI gets a fresh session.
        // CLOEXEC_DEFAULT: the child inherits nothing but its pty stdio.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        var arguments = Self.cStrings(argv)
        var environment = Self.childEnvironment()
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &actions, &attributes,
                                 &arguments, &environment)
        guard result == 0 else { throw LaunchError.spawnFailed(result) }

        let server = Server(pid: pid, master: master,
                            onOutput: onOutput, onExit: onExit)
        ownsMaster = false  // the server closes it, via its read source
        server.start()
        return server
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw LaunchError.spawnSetupFailed(code) }
    }

    private func nonNegative(_ value: Int32) -> Int32? { value < 0 ? nil : value }

    /// The app's environment plus a TERM the CLI can render into, if the app
    /// was launched without one (Finder/launchd give none). The existing
    /// entries are copied as raw C strings: a Swift round-trip would mangle any
    /// value that is not valid UTF-8.
    private static func childEnvironment() -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        var hasTerm = false
        var entry = environ
        while let value = entry.pointee {
            if strncmp(value, "TERM=", 5) == 0 { hasTerm = true }
            result.append(strdup(value))
            entry += 1
        }
        if !hasTerm { result.append(strdup("TERM=xterm-256color")) }
        result.append(nil)
        return result
    }

    /// NULL-terminated argv; the caller frees the copies.
    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        result.append(nil)
        return result
    }
}
