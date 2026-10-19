import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

/// Final shared evaluation trace and checked resource counters.
public struct NetlistEvaluationProvenance: Sendable {
    public let temperatures: NetlistTemperatureProvenance
    /// Exact evaluated source-unit scalar inventory, before derived numerical preparation.
    public let sourceScalars: [NetlistSourceScalarOverride]
    public let profile: MOSInputProfile
    public let evaluation: MOSEvaluationProvenance
    public let evaluationSteps: UInt64
    public let retainedBytes: UInt64
    public let peakOwnedBufferBytes: UInt64
    /// Dynamic immutable payload, independently of the completed session's ledger statistics.
    package func retainedPayloadByteCount() throws(MOSResolutionFailure) -> UInt64 {
        var payload = MOSStorageBudget(maximumBytes: .max, maximumSteps: .max)
        try payload.add(evaluation.retainedPayloadByteCount())
        try payload.addArray(sourceScalars)
        for scalar in sourceScalars {
            try payload.addText(scalar.instanceName)
            try payload.addText(scalar.parameterName)
        }
        return payload.bytes
    }

    public var seed: UInt64 { evaluation.seed }
    public var randomDraws: UInt64 { evaluation.randomDraws }
    public var randomGeneratorVersion: String { evaluation.randomGeneratorVersion }
    public var rootVisits: [MOSRootVisit] { evaluation.rootVisits }
}
