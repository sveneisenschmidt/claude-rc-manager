import Foundation

/// Parses `claude auth status` output. Anything but a parseable JSON object
/// with `"loggedIn": true` counts as logged out (spec: ClaudeCLI).
enum AuthStatus {
    private struct Payload: Decodable { let loggedIn: Bool }

    static func isLoggedIn(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Payload.self, from: data))?.loggedIn ?? false
    }
}
