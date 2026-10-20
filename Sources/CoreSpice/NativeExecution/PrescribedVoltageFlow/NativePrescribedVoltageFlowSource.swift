/// Conditional projections of one actual prescribed source; no common-function claim.
public struct NativePrescribedVoltageFlowSource: Sendable {
    public let deviceIndex: Int
    public let zeroVoltage: Double
    public let oneVoltage: Double
    public let timeOrigin: Double
    public let timeScale: Double
    public let initialNormalized: ClosedRange<Double>
    public let normalized: ClosedRange<Double>
    /// Bounds dU/dt in SI seconds almost everywhere, not derivatives at every point.
    public let normalizedDerivativePerSecond: ClosedRange<Double>
    public init(deviceIndex: Int, zeroVoltage: Double, oneVoltage: Double,
        timeOrigin: Double, timeScale: Double, initialNormalized: ClosedRange<Double>,
        normalized: ClosedRange<Double>, normalizedDerivativePerSecond: ClosedRange<Double>) {
        self.deviceIndex = deviceIndex; self.zeroVoltage = zeroVoltage; self.oneVoltage = oneVoltage
        self.timeOrigin = timeOrigin; self.timeScale = timeScale
        self.initialNormalized = initialNormalized; self.normalized = normalized
        self.normalizedDerivativePerSecond = normalizedDerivativePerSecond
    }
}
