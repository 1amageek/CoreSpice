/// Actual checked source association and the retained conditional interval assumptions.
public struct NativePrescribedVoltageFlowSourceScope: Sendable {
    public let deviceIndex: Int
    public let fact: NativeVoltageSourceFact
    public let assumptions: NativePrescribedVoltageFlowSource
    public let internalNormalizedSlope: ClosedRange<Double>
    internal init(deviceIndex: Int, fact: NativeVoltageSourceFact,
        assumptions: NativePrescribedVoltageFlowSource, internalNormalizedSlope: ClosedRange<Double>) {
        self.deviceIndex = deviceIndex; self.fact = fact
        self.assumptions = assumptions; self.internalNormalizedSlope = internalNormalizedSlope
    }
}
