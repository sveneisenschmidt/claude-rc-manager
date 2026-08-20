import Foundation

/// Restart decisions after an unexpected exit (spec: Crash handling).
/// Crash-loop check first: 3 consecutive exits each within `fastExitWindow`
/// of start pause auto-restart. Otherwise back off 1,2,4,... capped at 60 s.
/// A run of >= `stableRunDuration` resets both counters; `reset()` is the
/// manual-start reset.
struct RestartPolicy: Equatable {
    enum Decision: Equatable {
        case restart(after: TimeInterval)
        case crashLoopPause
    }

    var fastExitWindow: TimeInterval = 5
    var stableRunDuration: TimeInterval = 300
    private var attempt = 0
    private var consecutiveFastExits = 0

    mutating func recordExit(runDuration: TimeInterval) -> Decision {
        if runDuration >= stableRunDuration {
            attempt = 0
            consecutiveFastExits = 0
        }
        if runDuration < fastExitWindow {
            consecutiveFastExits += 1
            if consecutiveFastExits >= 3 {
                return .crashLoopPause
            }
        } else {
            consecutiveFastExits = 0
        }
        attempt += 1
        let delay = min(60, pow(2, Double(attempt - 1)))
        return .restart(after: delay)
    }

    mutating func reset() {
        attempt = 0
        consecutiveFastExits = 0
    }
}
