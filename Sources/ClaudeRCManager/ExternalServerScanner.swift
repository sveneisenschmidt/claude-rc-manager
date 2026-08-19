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
