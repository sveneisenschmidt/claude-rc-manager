import XCTest
@testable import ClaudeRCManager

/// Key parity across the shipped catalogs.
///
/// Two traps this test is written around (both probe-verified): a
/// runtime-discovered locale set would make the test pass when a locale is
/// missing entirely, so the expected set is hard-coded; and
/// `paths(forResourcesOfType:)` returns only the NEGOTIATED localization's
/// file, not one per language, so every table is read through
/// `path(forResource:…forLocalization:)`.
final class LocalizationParityTests: XCTestCase {
    /// TODO: extend to ["en", "de", "fr", "es", "it", "ja", "zh-hans"] as the
    /// translation tasks land (zh-hans lowercase: SwiftPM lowercases lproj
    /// names in the emitted bundle). A task that forgets to extend this set
    /// leaves the test green on a missing locale — that is why it is
    /// hard-coded rather than discovered.
    private let expected: Set<String> = ["en"]

    private func keys(_ locale: String) throws -> [String: String] {
        let path = try XCTUnwrap(L10n.bundle.path(
            forResource: "Localizable", ofType: "strings",
            inDirectory: nil, forLocalization: locale),
            "\(locale).lproj/Localizable.strings missing")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String],
                             "\(locale).lproj/Localizable.strings is not a string table")
    }

    /// Conversion characters in order, with `%n$` positions and flags,
    /// width and precision stripped; `%%` is a literal, not an argument.
    /// A translation that drops or retypes a `%@`/`%d` corrupts
    /// `String(format:)` at runtime, so this is compared as a multiset.
    private func specifiers(_ format: String) -> [Character] {
        var result: [Character] = []
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { i += 1; continue }
            i += 1
            guard i < chars.count else { break }
            if chars[i] == "%" { i += 1; continue }
            // positional prefix: digits followed by '$'
            var j = i
            while j < chars.count, chars[j].isNumber { j += 1 }
            if j < chars.count, chars[j] == "$", j > i { i = j + 1 }
            // flags, width, precision, length modifiers
            while i < chars.count,
                  "-+ #0123456789.'hlLqjzt".contains(chars[i]) { i += 1 }
            if i < chars.count { result.append(chars[i]); i += 1 }
        }
        return result.sorted()
    }

    func testExpectedLocalizationsArePresent() {
        let available = Set(L10n.bundle.localizations)
        XCTAssertTrue(available.isSuperset(of: expected),
                      "missing localizations: \(expected.subtracting(available).sorted())")
    }

    func testEnglishBaseIsNonEmpty() throws {
        XCTAssertFalse(try keys("en").isEmpty, "the en base catalog is empty")
    }

    func testEveryLocaleHasExactlyTheEnglishKeys() throws {
        let base = try keys("en")
        let baseKeys = Set(base.keys)
        for locale in expected.subtracting(["en"]).sorted() {
            let table = try keys(locale)
            let localeKeys = Set(table.keys)
            XCTAssertEqual(localeKeys, baseKeys,
                           "\(locale): missing \(baseKeys.subtracting(localeKeys).sorted()), "
                           + "extra \(localeKeys.subtracting(baseKeys).sorted())")
            for key in baseKeys.intersection(localeKeys) {
                XCTAssertEqual(specifiers(table[key]!), specifiers(base[key]!),
                               "\(locale): format specifiers differ for \(key)")
            }
        }
    }

    /// The specifier extraction itself must be trustworthy — it is the only
    /// thing standing between a broken translation and a runtime crash.
    func testSpecifierExtraction() {
        XCTAssertEqual(specifiers("no args"), [])
        XCTAssertEqual(specifiers("%@ — Settings"), ["@"])
        XCTAssertEqual(specifiers("100%% of %d"), ["d"])
        XCTAssertEqual(specifiers("%2$@ vor %1$d"), ["@", "d"])
        XCTAssertEqual(specifiers("%1$d von %2$@"), specifiers("%2$@ aus %1$d"))
        XCTAssertNotEqual(specifiers("%@"), specifiers("%d"))
        XCTAssertNotEqual(specifiers("%@ %@"), specifiers("%@"))
    }
}
