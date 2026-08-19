import XCTest
@testable import ClaudeRCManager

final class FolderConfigTests: XCTestCase {
    func testDefaults() {
        let f = FolderConfig(path: "/tmp/proj")
        XCTAssertEqual(f.name, "proj")
        XCTAssertEqual(f.spawnMode, .sameDir)
        XCTAssertFalse(f.createSessionInDir) // standby default
        XCTAssertEqual(f.capacity, 32)
        XCTAssertNil(f.permissionMode)
        XCTAssertEqual(f.extraArgs, "")
        XCTAssertFalse(f.autostart)
        XCTAssertTrue(f.autoRestart)
    }

    func testCodableRoundTrip() throws {
        var f = FolderConfig(path: "/tmp/proj")
        f.spawnMode = .worktree
        f.permissionMode = .acceptEdits
        let config = AppConfig(folders: [f])
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(back, config)
        XCTAssertEqual(back.version, 1)
    }
}
