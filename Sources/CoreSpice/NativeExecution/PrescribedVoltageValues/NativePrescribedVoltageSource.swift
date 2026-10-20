/// Explicit conditional external coordinates for one actual selected voltage-source device.
package struct NativePrescribedVoltageSource: Sendable {
    package let deviceIndex: Int
    package let zeroVoltage: Double
    package let oneVoltage: Double
    package let timeOrigin: Double
    package let timeScale: Double
    package let normalized: ClosedRange<Double>
    package let leftSlope: ClosedRange<Double>
    package let rightSlope: ClosedRange<Double>
    package init(deviceIndex: Int, zeroVoltage: Double, oneVoltage: Double, timeOrigin: Double,
        timeScale: Double, normalized: ClosedRange<Double>, leftSlope: ClosedRange<Double>, rightSlope: ClosedRange<Double>) {
        self.deviceIndex = deviceIndex; self.zeroVoltage = zeroVoltage; self.oneVoltage = oneVoltage
        self.timeOrigin = timeOrigin; self.timeScale = timeScale; self.normalized = normalized
        self.leftSlope = leftSlope; self.rightSlope = rightSlope
    }
}
