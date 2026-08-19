import Foundation

/// Appends a server's pty output to its log file. The pty stream contains
/// ANSI escapes and CR overwrites (spec: Command and process tree); filter
/// them so the log is readable in a text editor.
final class LogWriter {
    private let handle: FileHandle
    let url: URL

    /// CSI (ESC [ ... final byte), OSC (ESC ] ... BEL or ESC \), other
    /// two-byte ESC sequences, then lone CR and BS characters.
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|\u{1B}[@-_]|[\r\u{08}]"
    )

    static func filter(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    static func rotateIfNeeded(at url: URL, maxBytes: Int = 5 * 1024 * 1024) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes else { return }
        let old = URL(fileURLWithPath: url.path + ".old")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        LogWriter.rotateIfNeeded(at: url)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    func append(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        let filtered = LogWriter.filter(text)
        if let data = filtered.data(using: .utf8), !data.isEmpty {
            handle.write(data)
        }
    }

    deinit { try? handle.close() }
}
