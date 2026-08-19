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
        XCTAssertEqual(store.load(), .fresh(AppConfig()))
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = ConfigStore(directory: dir)
        var config = AppConfig()
        config.folders.append(FolderConfig(path: "/tmp/a"))
        try store.save(config)
        XCTAssertEqual(store.load(), .fresh(config))
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
}
