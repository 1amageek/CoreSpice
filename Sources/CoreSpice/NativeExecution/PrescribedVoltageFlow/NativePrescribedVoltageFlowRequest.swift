import CoreSpiceDevices

/// Finite proposals and conditional source assumptions; no charge, field or proof callback.
public struct NativePrescribedVoltageFlowRequest: Sendable {
    public let originalLower: [CompensatedValue]
    public let originalUpper: [CompensatedValue]
    public let startTime: CompensatedValue
    public let duration: CompensatedValue
    public let sources: [NativePrescribedVoltageFlowSource]
    public let algebraicRows: [Int]
    public let dynamicInitialCoordinates: [CompensatedEnclosure]
    public let initial: NativePrescribedVoltageFlowRootProposal
    public let chargeBox: [CompensatedEnclosure]
    public let window: NativePrescribedVoltageFlowRootProposal
    public init(originalLower: [CompensatedValue], originalUpper: [CompensatedValue],
        startTime: CompensatedValue, duration: CompensatedValue,
        sources: [NativePrescribedVoltageFlowSource], algebraicRows: [Int],
        dynamicInitialCoordinates: [CompensatedEnclosure], initial: NativePrescribedVoltageFlowRootProposal,
        chargeBox: [CompensatedEnclosure], window: NativePrescribedVoltageFlowRootProposal) {
        self.originalLower = originalLower; self.originalUpper = originalUpper
        self.startTime = startTime; self.duration = duration; self.sources = sources
        self.algebraicRows = algebraicRows; self.dynamicInitialCoordinates = dynamicInitialCoordinates
        self.initial = initial; self.chargeBox = chargeBox; self.window = window
    }
}
