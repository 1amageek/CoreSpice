import CoreSpiceDevices

/// Data associated with its owning observation result; rates are V per SI second almost everywhere.
public struct NativePrescribedVoltageFlowVoltageObservation: Sendable {
    public let pair: NativePrescribedVoltageFlowVoltagePair
    public let initialVoltage: CompensatedEnclosure
    public let windowVoltage: CompensatedEnclosure
    public let almostEverywhereRate: CompensatedEnclosure
    internal init(pair: NativePrescribedVoltageFlowVoltagePair, initialVoltage: CompensatedEnclosure,
        windowVoltage: CompensatedEnclosure, almostEverywhereRate: CompensatedEnclosure) {
        self.pair = pair; self.initialVoltage = initialVoltage; self.windowVoltage = windowVoltage
        self.almostEverywhereRate = almostEverywhereRate
    }
}
