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

    func testDuplicateFolderIDsAreRekeyedOnLoad() throws {
        // A hand-copied entry in config.json repeats an id; ids key the menu
        // and process lookup, so the duplicate must be re-keyed on load.
        var a = FolderConfig(path: "/tmp/a")
        var b = FolderConfig(path: "/tmp/b")
        b.id = a.id
        var c = FolderConfig(path: "/tmp/c")
        c.id = a.id
        var config = AppConfig()
        config.folders = [a, b, c]
        let store = ConfigStore(directory: dir)
        try store.save(config)

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("a well-formed file must load")
        }
        XCTAssertEqual(loaded.folders.map(\.path), ["/tmp/a", "/tmp/b", "/tmp/c"],
                       "order must be preserved")
        XCTAssertEqual(Set(loaded.folders.map(\.id)).count, 3, "ids must be unique")
        XCTAssertEqual(loaded.folders[0].id, a.id, "the first occurrence keeps its id")
        // Everything else about the duplicates is untouched.
        a.id = loaded.folders[0].id
        XCTAssertEqual(loaded.folders[0], a)
    }
}
