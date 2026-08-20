import XCTest
@testable import ClaudeRCManager

final class ExternalServerScannerTests: XCTestCase {
    func testParsePgrepFiltersAndExcludesOwnPids() {
        let output = """
        123 /Users/x/.local/bin/claude remote-control --spawn same-dir
        456 grep remote-control
        555 /usr/bin/grep claude remote-control
        789 /usr/local/bin/claude remote-control
        999 /Users/x/.local/bin/claude remote-control
        """
        let hits = ExternalServerScanner.parsePgrep(output, excluding: [999])
        XCTAssertEqual(hits.map(\.pid), [123, 789])
        XCTAssertTrue(hits[0].command.contains("remote-control"))
    }

    func testParseLsofCwd() {
        let output = "p123\nfcwd\nn/Users/x/proj\n"
        XCTAssertEqual(ExternalServerScanner.parseLsofCwd(output), "/Users/x/proj")
    }

    func testParseLsofCwdMissing() {
        XCTAssertNil(ExternalServerScanner.parseLsofCwd("p123\n"))
    }
}
