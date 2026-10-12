import CoreSpiceMOSContracts

/// A failed consuming bootstrap retains bounded diagnostics after its session is released.
public struct MOSConditionEvaluationFailure: Error, Sendable {
    public let cause: MOSResolutionFailure
    public let diagnostic: MOSResolutionDiagnostic?
}
