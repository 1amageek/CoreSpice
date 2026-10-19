import CoreSpiceOSDI
import OSDIContracts

/// Retained acquisition and resource policy for fresh native model setup on every run.
public struct SPICEOSDIRuntimeInputs: Sendable {
    public let provider: any OSDILibraryProviding
    public let loadLimits: OSDILoadLimits
    public let evaluationLimits: OSDIEvaluationLimits
    public let maximumInstanceCount: Int
    public let maximumAdapterBytes: UInt64
    public let tolerances: SPICEOSDITolerances
    public let transientPrecision: OSDITransientPrecisionInputs?
    public init(provider: any OSDILibraryProviding, loadLimits: OSDILoadLimits,
                evaluationLimits: OSDIEvaluationLimits, maximumInstanceCount: Int,
                maximumAdapterBytes: UInt64, tolerances: SPICEOSDITolerances,
                transientPrecision: OSDITransientPrecisionInputs? = nil) throws(OSDIAdapterFailure) {
        guard maximumInstanceCount > 0, maximumAdapterBytes > 0 else { throw .capacityExceeded }
        self.provider = provider; self.loadLimits = loadLimits; self.evaluationLimits = evaluationLimits
        self.maximumInstanceCount = maximumInstanceCount; self.maximumAdapterBytes = maximumAdapterBytes
        self.tolerances = tolerances
        self.transientPrecision = transientPrecision
    }
}
