import Foundation

public enum CoreSpiceSimulationExecutionError: Error, Sendable, Equatable, Hashable, LocalizedError {
    case completionPrecedesStart(startedAt: Date, completedAt: Date)
    case nonFiniteTimestamp(kind: String, value: Double)

    public var errorDescription: String? {
        switch self {
        case .completionPrecedesStart(let startedAt, let completedAt):
            "CoreSpice execution completed at \(completedAt) before it started at \(startedAt)."
        case .nonFiniteTimestamp(let kind, let value):
            "CoreSpice \(kind.lowercased()) timestamp must be finite; received \(value)."
        }
    }
}
