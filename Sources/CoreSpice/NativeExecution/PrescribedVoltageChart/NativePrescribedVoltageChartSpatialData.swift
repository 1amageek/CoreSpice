import CoreSpiceDevices

/// Immutable numerical planes/actions bound by the enclosing chart's original source scopes.
internal struct NativePrescribedVoltageChartSpatialData: Sendable {
    let dynamicStaticNormUpperBound: Double
    let staticResidual: [CompensatedEnclosure]
    let leftSlopes: [CompensatedEnclosure]
    let rightSlopes: [CompensatedEnclosure]
    let inputChargeLeft: [CompensatedEnclosure]
    let inputChargeRight: [CompensatedEnclosure]
    let inputStaticLeft: [CompensatedEnclosure]
    let inputStaticRight: [CompensatedEnclosure]
    let sourceCharges: [NativePrescribedVoltageChartSourceCharge]
}

extension NativePrescribedVoltageChartSpatialData {
    /// Outward enclosure of exact represented domain endpoints, including their low components.
    static func enclosure(lower: CompensatedValue, upper: CompensatedValue) throws -> CompensatedEnclosure {
        let lo = try CompensatedEnclosure(center: lower), hi = try CompensatedEnclosure(center: upper)
        let half = try CompensatedEnclosure(center: .init(high: 0.5))
        let midpoint = try lo.multiplied(by: half).adding(hi.multiplied(by: half))
        let selected = try CompensatedEnclosure(center: midpoint.center)
        let radius = max(try lo.subtracting(selected).absoluteUpperBound,
            try hi.subtracting(selected).absoluteUpperBound)
        return try .init(center: selected.center, radius: radius)
    }
}
