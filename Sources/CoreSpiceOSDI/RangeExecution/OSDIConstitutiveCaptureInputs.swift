import CircuiteFoundation
import OSDIContracts
import OSDIRuntime

/// Explicit operation-5 execution capabilities; accounting comes from the actual snapshot.
package struct OSDIConstitutiveCaptureInputs: Sendable {
    package let preparer: any OSDIPrecisionConstitutiveSessionPreparing
    package let evaluator: any OSDIPrecisionConstitutiveEvaluating
    package let worker: ArtifactAccessIntent
    package let source: any ArtifactAccessing
    package let numericProfile: ContentDigest
    package let options: OSDIPrecisionOptions
    package let coverLimits: OSDIPrecisionDecisionCoverLimits
    package let limits: OSDIPrecisionConstitutiveLimits
    package init(preparer: any OSDIPrecisionConstitutiveSessionPreparing,
        evaluator: any OSDIPrecisionConstitutiveEvaluating, worker: ArtifactAccessIntent,
        source: any ArtifactAccessing, numericProfile: ContentDigest, options: OSDIPrecisionOptions,
        coverLimits: OSDIPrecisionDecisionCoverLimits, limits: OSDIPrecisionConstitutiveLimits) {
        self.preparer = preparer; self.evaluator = evaluator; self.worker = worker; self.source = source
        self.numericProfile = numericProfile; self.options = options; self.coverLimits = coverLimits; self.limits = limits
    }
}
