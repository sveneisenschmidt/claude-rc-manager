import Foundation

/// Builds the argv for one folder's server (spec: Command and process tree).
/// The launcher supplies the pty, so argv starts at the CLI itself; capacity is
/// omitted in session mode (the CLI scopes it to worktree/same-dir); extra args
/// are appended last.
enum CommandBuilder {
    static func argv(for folder: FolderConfig, claudePath: String) -> [String] {
        var argv = [
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
