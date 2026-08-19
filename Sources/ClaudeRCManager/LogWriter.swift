import Foundation

/// Appends a server's pty output to its log file. The pty stream contains
/// ANSI escapes and CR overwrites (spec: Command and process tree); filter
/// them so the log is readable in a text editor.
///
/// Reads arrive in arbitrary chunks, so an escape sequence or a multi-byte
/// UTF-8 codepoint can straddle two `append` calls. Only the prefix that
/// ends on a safe boundary is written; the rest is carried over in `pending`.
/// Thread-safe: `append` arrives on the pty pump's background queue while
/// `close` runs from the main actor, so all mutable state sits behind a lock.
final class LogWriter {
    private let handle: FileHandle
    private let lock = NSLock()
    private var pending = Data()
    private var closed = false
    let url: URL

    /// Bytes we are willing to hold back waiting for a boundary. Beyond this
    /// the carry-over is force-flushed so a malformed stream cannot grow it.
    private static let maxCarryOver = 4096

    /// CSI (ESC [ params intermediates final), OSC (ESC ] ... BEL or ESC \),
    /// other Fp/nF/Fs escapes (ESC ( B, ESC =, ESC >, ...), then lone CR and BS.
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]"
            + "|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
            + "|\u{1B}[ -/]*[0-Z\\\\^-~]"
            + "|[\r\u{08}]"
    )

    static func filter(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Length of the largest prefix of `data` that ends on a UTF-8 boundary
    /// and outside an escape sequence. Returns an OFFSET, not an index:
    /// callers pass sliced Data (`pending` after removeFirst has a non-zero
    /// startIndex), so all subscripts below go through `startIndex + i`.
    static func safeSplit(_ data: Data) -> Int {
        var end = data.count
        // Back off an incomplete trailing escape sequence. Unbounded scan:
        // a long OSC (window title) easily exceeds 64 bytes, and the
        // maxCarryOver force-flush already bounds total held-back bytes.
        var i = data.count - 1
        while i >= 0 {
            if data[data.startIndex + i] == 0x1B { end = min(end, i); break }
            i -= 1
        }
        // Back off an incomplete trailing UTF-8 codepoint.
        var j = end - 1
        while j >= 0, j > end - 4 {
            let b = data[data.startIndex + j]
            if b & 0b1100_0000 == 0b1000_0000 { j -= 1; continue }  // continuation byte
            let need = b < 0x80 ? 1 : (b < 0xE0 ? 2 : (b < 0xF0 ? 3 : 4))
            if j + need > end { end = j }
            break
        }
        return max(0, end)
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
        try handle.seekToEnd()
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pending.append(chunk)
        var split = LogWriter.safeSplit(pending)
        if split == 0 && pending.count > LogWriter.maxCarryOver { split = pending.count }
        guard split > 0 else { return }
        let ready = Data(pending.prefix(split))
        pending.removeFirst(split)
        write(ready)
    }

    /// Flushes whatever is still held back and closes the handle. Idempotent.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if !pending.isEmpty {
            let rest = pending
            pending.removeAll()
            write(rest)
        }
        try? handle.close()
    }

    /// `FileHandle.write(_:)` is the ObjC overload: it raises an uncatchable
    /// NSException on a full disk. The throwing variant reports instead.
    private func write(_ data: Data) {
        // String(decoding:) never fails; invalid bytes become U+FFFD.
        let filtered = LogWriter.filter(String(decoding: data, as: UTF8.self))
        guard !filtered.isEmpty else { return }
        try? handle.write(contentsOf: Data(filtered.utf8))
    }

    deinit { close() }
}
