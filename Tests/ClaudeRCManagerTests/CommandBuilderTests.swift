import XCTest
@testable import ClaudeRCManager

final class CommandBuilderTests: XCTestCase {
    func testDefaultStandbyCommand() {
        let f = FolderConfig(path: "/tmp/proj")
        let argv = CommandBuilder.argv(for: f, claudePath: "/usr/local/bin/claude")
        XCTAssertEqual(argv, [
            "/usr/local/bin/claude", "remote-control",
            "--name", "proj",
            "--spawn", "same-dir",
            "--capacity", "32",
            "--no-create-session-in-dir",
        ])
    }

    func testWorktreeModeWithQuotedExtraArgs() {
        var f = FolderConfig(path: "/tmp/proj")
        f.spawnMode = .worktree
        f.capacity = 7
        f.extraArgs = #"--debug-file "/tmp/my logs/rc.log""#
        let argv = CommandBuilder.argv(for: f, claudePath: "/x/claude")
        XCTAssertEqual(argv, [
            "/x/claude", "remote-control",
            "--name", "proj",
            "--spawn", "worktree",
            "--capacity", "7",
            "--no-create-session-in-dir",
            "--debug-file", "/tmp/my logs/rc.log",
        ])
    }

    func testSessionModeOmitsCapacityAndKeepsFlags() {
        var f = FolderConfig(path: "/tmp/proj")
        f.spawnMode = .session
        f.createSessionInDir = true
        f.permissionMode = .plan
        f.extraArgs = "--verbose"
        let argv = CommandBuilder.argv(for: f, claudePath: "/x/claude")
        XCTAssertEqual(argv, [
            "/x/claude", "remote-control",
            "--name", "proj",
            "--spawn", "session",
            "--create-session-in-dir",
            "--permission-mode", "plan",
            "--verbose",
        ])
    }
}
