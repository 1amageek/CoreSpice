/// Chart admission refusals; numerical and source failures retain their original types.
package enum NativePrescribedVoltageChartFailure: Error, Sendable, Equatable {
    case invalidInput, wrongOwner, invalidBinding, missingCaptureCapability, missingSmoothCapture
    case unprovedNullRow, capacityExceeded
}
