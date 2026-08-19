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

    func testMinimalJSONDecodesWithDefaults() throws {
        let json = #"{"version":1,"folders":[{"path":"/tmp/a"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.folders.count, 1)
        let f = config.folders[0]
        XCTAssertEqual(f.path, "/tmp/a")
        XCTAssertEqual(f.name, "a")
        XCTAssertEqual(f.spawnMode, .sameDir)
        XCTAssertFalse(f.createSessionInDir)
        XCTAssertEqual(f.capacity, 32)
        XCTAssertNil(f.permissionMode)
        XCTAssertEqual(f.extraArgs, "")
        XCTAssertFalse(f.autostart)
        XCTAssertTrue(f.autoRestart)
    }

    func testUnknownSpawnModeFallsBackToSameDir() throws {
        let json = #"{"version":1,"folders":[{"path":"/tmp/a","spawnMode":"bogus-mode"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.folders[0].spawnMode, .sameDir)
    }
}
