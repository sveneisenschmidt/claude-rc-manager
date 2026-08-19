import Foundation

/// Icon aggregation (spec: Menu structure). `healthy` is false when not
/// logged in, the binary is missing, or the config was corrupt.
enum StatusIcon {
    enum Bucket: Equatable {
        case warning, active, neutral

        var symbolName: String {
            switch self {
            case .warning: return "exclamationmark.triangle"
            case .active: return "terminal.fill"
            case .neutral: return "terminal"
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
