import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts

/// Immutable trace transferred only when the exclusive session is consumed.
public struct MOSEvaluationProvenance: Sendable {
    public let environment: EvaluationEnvironment?
    public let seed: UInt64
    public let randomGeneratorVersion: String
    public let evaluatorVersion: String
    public let randomDraws: UInt64
    public let rootVisits: [MOSRootVisit]

    /// Dynamic result payload; the consumed session's caches and diagnostics are excluded.
    package func retainedPayloadByteCount() throws(MOSResolutionFailure) -> UInt64 {
        var payload = MOSStorageBudget(maximumBytes: .max, maximumSteps: .max)
        try payload.addArray(rootVisits)
        try payload.addText(randomGeneratorVersion)
        try payload.addText(evaluatorVersion)
        return payload.bytes
    }
}
