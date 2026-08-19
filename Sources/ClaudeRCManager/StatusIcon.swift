import Foundation

/// Icon aggregation (spec: Menu structure). `healthy` is false when not
/// logged in, the binary is missing, or the config was corrupt.
enum StatusIcon {
    enum Bucket: Equatable, Sendable {
        case warning, active, neutral

        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .active: return "terminal.fill"
            case .neutral: return "terminal"
            }
        }

        /// The three icons are shape-only; VoiceOver users get the state
        /// from here, so it must not be the same string for all buckets.
        var accessibilityDescription: String {
            switch self {
            case .warning: return "Claude RC Manager — warning"
            case .active: return "Claude RC Manager — active"
            case .neutral: return "Claude RC Manager — idle"
            }
        }
    }

    static func bucket(states: [ServerState], healthy: Bool) -> Bucket {
        if !healthy { return .warning }
        if states.contains(where: { if case .failed = $0 { return true }; return false }) {
            return .warning
        }
        if states.contains(where: \.isActive) { return .active }
        return .neutral
    }
}
