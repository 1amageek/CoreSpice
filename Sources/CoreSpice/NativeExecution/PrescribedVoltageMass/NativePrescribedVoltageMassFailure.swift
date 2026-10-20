package enum NativePrescribedVoltageMassFailure: Error, Sendable, Equatable {
    case invalidInput
    case wrongOwner
    case invalidBinding
    case missingSmoothCapture
    case capacityExceeded
    case emptyMass
}
