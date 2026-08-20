import Foundation

/// POSIX-like tokenizer for the per-folder extra-args field (spec:
/// Per-folder configuration). Whitespace splits; ' and " quote; \ escapes
/// the next character outside single quotes. Inside double quotes, \ only
/// escapes one of " \ ` $ (POSIX double-quote rule); before any other
/// character the backslash stays literal. No tilde/glob/variable
/// expansion — tokens go to argv directly, no shell involved.
enum ArgsTokenizer {
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasContent = false
        var it = input.makeIterator()
        var quote: Character? = nil

        while let c = it.next() {
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\" && q == "\"" {
                    if let next = it.next() {
                        if next == "\"" || next == "\\" || next == "`" || next == "$" {
                            current.append(next)
                        } else {
                            current.append("\\")
                            current.append(next)
                        }
                    } else {
                        current.append("\\")
                    }
                } else {
                    current.append(c)
                }
            } else if c == "'" || c == "\"" {
                quote = c
                hasContent = true
            } else if c == "\\" {
                current.append(it.next() ?? "\\")
                hasContent = true
            } else if c.isWhitespace {
                if hasContent || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(c)
            }
        }
        if hasContent || !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
