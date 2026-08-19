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
}
