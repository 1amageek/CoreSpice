/// No refusal is a singularity, root or physical impossibility verdict.
package enum NativePrescribedVoltageFailure: Error, Sendable, Equatable {
    case invalidInput, invalidDomain, invalidBinding, missingControlledPreparation, missingCaptureCapability, capacityExceeded
    case unselectedDynamicSource(deviceIndex: Int)
    case sourceCurrentRead(device: String, row: Int)
    case sourceConstraintWrite(device: String, row: Int)
    case outsideOriginalDomain(row: Int)
}
