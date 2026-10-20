package enum NativePrescribedVoltageReconstructionFailure: Error, Sendable, Equatable {
    case invalidInput
    case invalidBinding
    case wrongOwner
    case missingSmoothCapture
    case capacityExceeded
    case outsideOriginalDomain(row: Int, side: NativePrescribedVoltageReconstruction.Side)
}
