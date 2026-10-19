import OSDIRuntime
import CoreSpiceOSDIContracts

public enum OSDIAdapterFailure: Error, Sendable {
    case runtime(OSDIError)
    case integration(OSDIIntegrationFailure)
    case invalidTopology
    case invalidMatrixMapping
    case identityMismatch
    case conditionsMismatch
    case unsupportedNature(node: Int, unknown: String, residual: String)
    case collapsedExternalNets
    case unsupportedAnalysis
    case capacityExceeded
    case cancelled
    case busy
    case closed
    case nonfiniteEvaluation
    case invalidNoiseSources
    case invalidIntegration
    case transientSessionRequired
    case transientTimeStepExceedsBound(requested: Double, maximum: Double)
    indirect case cleanupPending(cause: Self, owner: OSDIExecutionLifetime)
    indirect case cleanup(primary: Self, secondary: Self)
}
