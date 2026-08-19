import Foundation

/// Finds remote-control servers this app did not start (spec: External
/// servers). Display only. Output formats verified 2026-08-19:
/// `pgrep -fl` prints "pid command...", lsof -Fn prints p<pid>/fcwd/n<path>.
struct ExternalServer: Equatable, Sendable {
    let pid: pid_t
    let command: String
    var workingDirectory: String?
}

enum ExternalServerScanner {
    /// Matches on argv[0] — the claude binary itself, any path — with
    /// "remote-control" among the remaining arguments. Narrower than a
    /// whole-command substring search: e.g. `/usr/bin/grep claude
    /// remote-control` has argv[0] "grep" and is correctly excluded, where
    /// a plain "contains claude && contains remote-control" check would
    /// have matched it.
    static func parsePgrep(_ output: String, excluding ownPids: Set<pid_t>) -> [ExternalServer] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let pid = pid_t(parts[0]),
                  !ownPids.contains(pid) else { return nil }
            let command = String(parts[1])
            let argvParts = command.split(separator: " ", maxSplits: 1)
            guard let argv0 = argvParts.first,
                  (String(argv0) as NSString).lastPathComponent == "claude"
            else { return nil }
            let rest = argvParts.count > 1 ? String(argvParts[1]) : ""
            guard rest.contains("remote-control") else { return nil }
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
            timeout: 2),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        return parsePgrep(text, excluding: ownPids).map { server in
            var server = server
            if let out = ClaudeCLI.run(
                ["/usr/sbin/lsof", "-a", "-p", String(server.pid), "-d", "cwd", "-Fn"],
                timeout: 2),
               let text = String(data: out, encoding: .utf8)
            {
                server.workingDirectory = parseLsofCwd(text)
            }
            return server
        }
    }
}
