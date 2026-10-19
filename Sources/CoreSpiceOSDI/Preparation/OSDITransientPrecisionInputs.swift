import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Explicit host precision dependencies; no ordinary fallback is selected.
public struct OSDITransientPrecisionInputs: Sendable {
    public let preparer: any OSDIPrecisionSessionPreparing
    public let worker: ArtifactAccessIntent
    public let source: any ArtifactAccessing
    public let semanticProfile: ContentDigest
    public let numericProfile: ContentDigest
    public let options: OSDIPrecisionOptions
    public let precisionBits: UInt32
    public init(preparer: any OSDIPrecisionSessionPreparing, worker: ArtifactAccessIntent,
        source: any ArtifactAccessing, semanticProfile: ContentDigest, numericProfile: ContentDigest,
        options: OSDIPrecisionOptions, precisionBits: UInt32) {
        self.preparer = preparer; self.worker = worker; self.source = source
        self.semanticProfile = semanticProfile; self.numericProfile = numericProfile
        self.options = options; self.precisionBits = precisionBits
    }
}
