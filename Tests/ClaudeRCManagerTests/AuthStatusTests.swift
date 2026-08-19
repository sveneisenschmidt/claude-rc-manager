import XCTest
@testable import ClaudeRCManager

final class AuthStatusTests: XCTestCase {
    func testLoggedIn() {
        let json = Data(#"{"loggedIn": true, "authMethod": "claude.ai"}"#.utf8)
        XCTAssertTrue(AuthStatus.isLoggedIn(json))
    }

    func testLoggedOut() {
        XCTAssertFalse(AuthStatus.isLoggedIn(Data(#"{"loggedIn": false}"#.utf8)))
    }

    func testInvalidJSONMeansLoggedOut() {
        XCTAssertFalse(AuthStatus.isLoggedIn(Data("garbage".utf8)))
    }

    func testMissingFieldMeansLoggedOut() {
        XCTAssertFalse(AuthStatus.isLoggedIn(Data(#"{"email": "x@y.z"}"#.utf8)))
    }
}
