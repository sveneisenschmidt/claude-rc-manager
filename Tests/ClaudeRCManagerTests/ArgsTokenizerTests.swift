import XCTest
@testable import ClaudeRCManager

final class ArgsTokenizerTests: XCTestCase {
    func testEmpty() {
        XCTAssertEqual(ArgsTokenizer.tokenize(""), [])
        XCTAssertEqual(ArgsTokenizer.tokenize("   "), [])
    }

    func testWhitespaceSplit() {
        XCTAssertEqual(ArgsTokenizer.tokenize("--debug-file /tmp/x.log"),
                       ["--debug-file", "/tmp/x.log"])
        XCTAssertEqual(ArgsTokenizer.tokenize("--a\n--b"), ["--a", "--b"])
    }

    func testDoubleQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"--name "My Project""#),
                       ["--name", "My Project"])
    }

    func testSingleQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize("--name 'a b'"), ["--name", "a b"])
    }

    func testBackslashEscape() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"a\ b c"#), ["a b", "c"])
    }

    func testNoExpansion() {
        XCTAssertEqual(ArgsTokenizer.tokenize("~/x $HOME"), ["~/x", "$HOME"])
    }

    func testUnterminatedQuote() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"--name "a b"#), ["--name", "a b"])
    }

    func testEmptyQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"--x '' """#), ["--x", "", ""])
    }

    func testGluedDoubleQuote() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#"--name="a b""#), ["--name=a b"])
    }

    func testLiteralBackslashInDoubleQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#""a\nb""#), [#"a\nb"#])
    }

    func testEscapedQuoteInDoubleQuotes() {
        XCTAssertEqual(ArgsTokenizer.tokenize(#""say \"hi\"""#), [#"say "hi""#])
    }
}
