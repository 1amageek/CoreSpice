/// A refused candidate is not a singularity or physical impossibility verdict.
package enum NativeGlobalChargeFailure: Error, Sendable {
    case invalidInput
    case invalidDomain
    case illegalAnchor
    case invalidBinding
    case missingControlledPreparation
    case missingCaptureCapability
    case unprovedNullRow
    case capacityExceeded
}
