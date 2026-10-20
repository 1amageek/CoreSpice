import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Explicit operation-2 inputs; the evaluator is sealed inside the actual-bound bridge.
public struct OSDISmoothRangeCaptureInputs: Sendable {
    package let preparer: any OSDIPrecisionRangeSessionPreparing
    package let worker: ArtifactAccessIntent
    package let source: any ArtifactAccessing
    package let numericProfile: ContentDigest
    package let options: OSDIPrecisionOptions
    public init(preparer: OSDINativePrecisionSessionPreparer, worker: ArtifactAccessIntent,
        source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions) {
        self.preparer = preparer; self.worker = worker; self.source = source
        self.numericProfile = numericProfile; self.options = options
    }
    /// Trusted package fixture seam; external callers cannot substitute session preparation.
    package init(preparer: any OSDIPrecisionRangeSessionPreparing, worker: ArtifactAccessIntent,
        source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions) {
        self.preparer = preparer; self.worker = worker; self.source = source
        self.numericProfile = numericProfile; self.options = options
    }
}
