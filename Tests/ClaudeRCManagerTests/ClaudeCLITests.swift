import XCTest
@testable import ClaudeRCManager

final class ClaudeCLITests: XCTestCase {
    func testRunReturnsStdout() {
        let data = ClaudeCLI.run(["/bin/echo", "hi"], timeout: 5)
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "hi\n")
    }

    func testRunTimesOut() {
        let start = Date()
        XCTAssertNil(ClaudeCLI.run(["/bin/sleep", "30"], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunNonzeroExitReturnsNil() {
        XCTAssertNil(ClaudeCLI.run(["/usr/bin/false"], timeout: 5))
    }
}
