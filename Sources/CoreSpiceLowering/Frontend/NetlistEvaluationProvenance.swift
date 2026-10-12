import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

/// Final shared evaluation trace and checked resource counters.
public struct NetlistEvaluationProvenance: Sendable {
    public let temperatures: NetlistTemperatureProvenance
    public let profile: MOSInputProfile
    public let evaluation: MOSEvaluationProvenance
    public let evaluationSteps: UInt64
    public let retainedBytes: UInt64
    public let peakOwnedBufferBytes: UInt64
    public var seed: UInt64 { evaluation.seed }
    public var randomDraws: UInt64 { evaluation.randomDraws }
    public var randomGeneratorVersion: String { evaluation.randomGeneratorVersion }
    public var rootVisits: [MOSRootVisit] { evaluation.rootVisits }
}
