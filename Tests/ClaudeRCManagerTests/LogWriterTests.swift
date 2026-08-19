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

    func testStripsExtendedCSIAndCharsetEscapes() {
        XCTAssertEqual(LogWriter.filter("\u{1B}[38:2:255:0:0mRED"), "RED")
        XCTAssertEqual(LogWriter.filter("\u{1B}(Btext"), "text")
    }

    /// Reads arrive in arbitrary chunks: feeding a stream one byte at a time
    /// must produce the same file as feeding it in one go.
    func testByteByByteMatchesSingleChunk() throws {
        let dir = try makeTempDir()
        let source = Data("\u{1B}[31mR\u{00D6}T\u{1B}[0m\r\ndone".utf8)

        let chunkedFile = dir.appendingPathComponent("chunked.log")
        let chunked = try LogWriter(url: chunkedFile)
        for byte in source { chunked.append(Data([byte])) }
        chunked.close()

        let wholeFile = dir.appendingPathComponent("whole.log")
        let whole = try LogWriter(url: wholeFile)
        whole.append(source)
        whole.close()

        let chunkedBytes = try Data(contentsOf: chunkedFile)
        XCTAssertEqual(chunkedBytes, try Data(contentsOf: wholeFile))
        XCTAssertEqual(String(decoding: chunkedBytes, as: UTF8.self), "R\u{00D6}T\ndone")
    }

    func testLongOSCAcrossChunksIsStripped() throws {
        // A window-title OSC longer than 64 bytes must not leak when split.
        let dir = try makeTempDir()
        let title = "/Users/sven/Github/claude-rc-menubar - claude remote-control session"
        let source = Data("\u{1B}]0;\(title)\u{07}AFTER".utf8)

        let file = dir.appendingPathComponent("osc.log")
        let writer = try LogWriter(url: file)
        for byte in source { writer.append(Data([byte])) }
        writer.close()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "AFTER")
    }

    func testSafeSplitOnSlicedData() {
        // pending has a non-zero startIndex after removeFirst; safeSplit
        // must return an offset that is valid for sliced Data.
        var data = Data("xxabc\u{1B}".utf8)
        data.removeFirst(2)
        XCTAssertEqual(LogWriter.safeSplit(data), 3) // "abc", ESC held back
    }

    func testInitOnExistingFileAppends() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("x.log")

        let first = try LogWriter(url: file)
        first.append(Data("one\n".utf8))
        first.close()

        let second = try LogWriter(url: file)
        second.append(Data("two\n".utf8))
        second.close()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\ntwo\n")
    }

    func testCloseIsIdempotent() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("x.log")
        let w = try LogWriter(url: file)
        w.append(Data("hi".utf8))
        w.close()
        w.close()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hi")
    }

    func testNoRotationExactlyAtMaxBytes() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("x.log")
        try Data(repeating: 65, count: 5).write(to: file)

        LogWriter.rotateIfNeeded(at: file, maxBytes: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".old"))
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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
