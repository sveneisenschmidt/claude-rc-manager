import XCTest
@testable import ClaudeRCManager

final class ConfigStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileYieldsEmptyConfig() {
        let store = ConfigStore(directory: dir)
        XCTAssertEqual(store.load(), .loaded(AppConfig()))
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = ConfigStore(directory: dir)
        var config = AppConfig()
        config.folders.append(FolderConfig(path: "/tmp/a"))
        try store.save(config)
        XCTAssertEqual(store.load(), .loaded(config))
    }

    func testCorruptFileIsRenamedAndEmptyConfigReturned() throws {
        let file = dir.appendingPathComponent("config.json")
        try Data("not json{{".utf8).write(to: file)
        let store = ConfigStore(directory: dir)
        XCTAssertEqual(store.load(), .recoveredFromCorrupt(AppConfig()))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnreadableFileIsPreservedAsBackup() throws {
        // Root can read mode-000 files; the branch is unreachable then.
        try XCTSkipIf(getuid() == 0)
        let file = dir.appendingPathComponent("config.json")
        let original = #"{"version":1,"folders":[{"path":"/keepme"}]}"#
        try Data(original.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: file.path)
        let store = ConfigStore(directory: dir)
        XCTAssertEqual(store.load(), .recoveredFromCorrupt(AppConfig()))
        let bak = dir.appendingPathComponent("config.json.bak")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: bak.path)
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSaveOverExistingFileRoundTrips() throws {
        let store = ConfigStore(directory: dir)
        var first = AppConfig()
        first.folders.append(FolderConfig(path: "/tmp/a"))
        try store.save(first)
        XCTAssertEqual(store.load(), .loaded(first))

        var second = AppConfig()
        second.folders.append(FolderConfig(path: "/tmp/b"))
        try store.save(second)
        XCTAssertEqual(store.load(), .loaded(second))
    }
}
