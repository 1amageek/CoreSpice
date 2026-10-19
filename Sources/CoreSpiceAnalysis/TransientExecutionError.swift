import CoreSpiceIR

/// Fatal run admission failures; these must never be retried as nonconvergence.
public enum TransientExecutionError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingExecutionLimits
    case invalidLimit(name: String, value: Int)
    case limitExceeded(resource: String, limit: Int, requested: Int)
    case arithmeticOverflow(String)
    case invalidTimeStep(Double)
    case nonProgressingTime(time: Double, timeStep: Double)
    case nonFiniteLTE(Double)
    case unknownErrorControlVariable(MNAVariable)

    public var description: String {
        switch self {
        case .missingExecutionLimits: "Transient execution requires explicit caller-owned limits"
        case .invalidLimit(let name, let value): "Invalid transient limit \(name): \(value)"
        case .limitExceeded(let resource, let limit, let requested): "Transient \(resource) limit \(limit) exceeded by \(requested)"
        case .arithmeticOverflow(let operation): "Transient arithmetic overflow: \(operation)"
        case .invalidTimeStep(let step): "Invalid transient timestep: \(step)"
        case .nonProgressingTime(let time, let step): "Transient time cannot advance from \(time) by \(step)"
        case .nonFiniteLTE(let value): "Nonfinite transient LTE: \(value)"
        case .unknownErrorControlVariable(let variable): "Transient error-control variable is not in the execution plan: \(variable)"
        }
    }
}
