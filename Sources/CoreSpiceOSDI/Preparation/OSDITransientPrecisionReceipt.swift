import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Immutable inspection evidence; it grants no process or model execution authority.
public struct OSDITransientPrecisionReceipt: Sendable {
    public let program: OSDIPrecisionProgram
    public let workerReference: ArtifactReference
    public let numericProfile: ContentDigest
    public let options: OSDIPrecisionOptions
    public let precisionBits: UInt32
    public init(program: OSDIPrecisionProgram, workerReference: ArtifactReference,
        numericProfile: ContentDigest, options: OSDIPrecisionOptions, precisionBits: UInt32) {
        self.program = program; self.workerReference = workerReference; self.numericProfile = numericProfile
        self.options = options; self.precisionBits = precisionBits
    }
}
