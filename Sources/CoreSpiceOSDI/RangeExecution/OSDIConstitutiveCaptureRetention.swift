import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Source/mapping backing retention only; the actual query box remains caller-owned.
package struct OSDIConstitutiveCaptureRetention: Sendable {
    package let source: OSDIPrecisionConstitutiveBinding
    package let workerReference: ArtifactReference
    package let numericProfile: ContentDigest
    package let options: OSDIPrecisionOptions
    package let coverLimits: OSDIPrecisionDecisionCoverLimits
    package let identityLimits: OSDIPrecisionConstitutiveLimits
    private let snapshot: OSDIConstitutiveSnapshot
    private let inventory: OSDIConstitutiveInventory
    init(source: OSDIPrecisionConstitutiveBinding, workerReference: ArtifactReference, numericProfile: ContentDigest,
        options: OSDIPrecisionOptions, coverLimits: OSDIPrecisionDecisionCoverLimits,
        identityLimits: OSDIPrecisionConstitutiveLimits, snapshot: OSDIConstitutiveSnapshot, inventory: OSDIConstitutiveInventory) {
        self.source = source; self.workerReference = workerReference; self.numericProfile = numericProfile
        self.options = options; self.coverLimits = coverLimits; self.identityLimits = identityLimits
        self.snapshot = snapshot; self.inventory = inventory
    }
    package func withInventory<Result>(_ body: (OSDIConstitutiveInventoryView) throws -> Result) rethrows -> Result {
        try inventory.withView(retention: self, body)
    }
}
