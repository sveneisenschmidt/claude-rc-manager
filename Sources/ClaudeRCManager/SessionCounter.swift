import Foundation

/// Reads the session count the CLI prints on every redraw
/// (`Capacity: <live>/<max>`) out of one server's pty stream.
///
/// Fed from the pty reader thread, like the LogWriter, so the mutable state
/// sits behind a lock. `onChange` is called on the feeding thread and only
/// when the number actually changes; the receiver hops to the main actor.
final class SessionCounter: @unchecked Sendable {
    /// Characters kept from the end of a chunk, so a `Capacity: 2/32` split
    /// across two reads is still matched. Ten times the longest match this
    /// looks for, which also covers an escape sequence caught mid-flight.
    static let carryOver = 256

    private static let pattern = try! NSRegularExpression(
        pattern: "Capacity: *([0-9]+)/[0-9]+")

    private let lock = NSLock()
    private var pending = ""
    private var count: Int?

    /// Set once, before the server is launched, so no feed can race it.
    var onChange: ((Int) -> Void)?

    /// The last count in `text`, or nil when there is none.
    static func lastCount(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.matches(in: text, range: range).last,
              let digits = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[digits])
    }

    /// The tail carried into the next chunk.
    static func tail(of text: String) -> String {
        String(text.suffix(carryOver))
    }

    func feed(_ chunk: Data) {
        var report: Int?
        lock.lock()
        // Filtering first: the stream carries ANSI escapes, which can sit
        // between "Capacity:" and the digits. The carried-over tail is
        // filtered again, which it needs: an escape sequence cut in half by
        // the read boundary survives the first pass and is only removable
        // once the rest of it has arrived.
        let text = LogWriter.filter(pending + String(decoding: chunk, as: UTF8.self))
        if let value = Self.lastCount(in: text), value != count {
            count = value
            report = value
        }
        pending = Self.tail(of: text)
        lock.unlock()
        if let report { onChange?(report) }
    }
}
