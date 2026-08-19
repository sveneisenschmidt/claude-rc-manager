import XCTest
@testable import ClaudeRCManager

final class LogWriterTests: XCTestCase {
    func testStripsCSISequences() {
        XCTAssertEqual(LogWriter.filter("\u{1B}[31mRED\u{1B}[0m\r\n"), "RED\n")
    }

    func testStripsOSCSequences() {
        XCTAssertEqual(LogWriter.filter("\u{1B}]0;title\u{07}text"), "text")
    }

    func testDropsCarriageReturnsAndBackspaces() {
        XCTAssertEqual(LogWriter.filter("a\u{08}b\rline\r\n"), "abline\n")
    }

    func testRotationAtThreshold() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.log")
        try Data(repeating: 65, count: 10).write(to: file)

        LogWriter.rotateIfNeeded(at: file, maxBytes: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".old"))

        // Under the threshold: nothing happens.
        try Data(repeating: 66, count: 3).write(to: file)
        LogWriter.rotateIfNeeded(at: file, maxBytes: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
