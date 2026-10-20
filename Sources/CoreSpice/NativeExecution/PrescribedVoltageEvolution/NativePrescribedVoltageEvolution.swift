import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent

/// Conditional matched-chart rates and full-row current reconstructions, without history authority.
package final class NativePrescribedVoltageEvolution: Sendable {
    package let dimension: Int
    package let reducedCoordinateCount: Int
    package let chargeCoordinateCount: Int
    package var chargeStateLipschitzUpperBound: Double { payload.chargeStateLipschitzUpperBound }
    private let payload: Payload
    private init(_ payload: Payload) {
        self.payload = payload; dimension = payload.leftCharge.count
        reducedCoordinateCount = payload.chart.dimension; chargeCoordinateCount = payload.chargeRates.count
    }
    internal static func reconstruct(record: NativeCircuitPreparationRecord,
        chart: NativePrescribedVoltageChart, limits: NativePrescribedVoltageEvolutionLimits,
        cancellation: CancellationToken) throws -> Self {
        Self(try NativePrescribedVoltageEvolutionAssembly.reconstruct(record: record, chart: chart,
            limits: limits, cancellation: cancellation))
    }
    package func chargeRate(at index: Int) throws -> CompensatedEnclosure {
        guard payload.chargeRates.indices.contains(index) else { throw NativePrescribedVoltageEvolutionFailure.invalidInput }
        return payload.chargeRates[index]
    }
    package func reducedRate(at index: Int, side: NativePrescribedVoltageReconstruction.Side) throws -> CompensatedEnclosure {
        guard (0..<reducedCoordinateCount).contains(index) else { throw NativePrescribedVoltageEvolutionFailure.invalidInput }
        return (side == .left ? payload.leftRates : payload.rightRates)[index]
    }
    package func fullChargeRate(at row: Int, side: NativePrescribedVoltageReconstruction.Side) throws -> CompensatedEnclosure {
        guard (0..<dimension).contains(row) else { throw NativePrescribedVoltageEvolutionFailure.invalidInput }
        return (side == .left ? payload.leftCharge : payload.rightCharge)[row]
    }
    package func coordinate(at row: Int, side: NativePrescribedVoltageReconstruction.Side) throws -> CompensatedEnclosure {
        try (side == .left ? payload.left : payload.right).coordinate(at: row)
    }
    package func selectedCurrent(at index: Int, side: NativePrescribedVoltageReconstruction.Side) throws -> CompensatedEnclosure {
        guard payload.branches.indices.contains(index) else { throw NativePrescribedVoltageEvolutionFailure.invalidInput }
        return try coordinate(at: payload.branches[index], side: side)
    }
    /// The matched affine voltage derivative; no selected-current derivative is available.
    internal func voltageRateLift(record: NativeCircuitPreparationRecord, cancellation: CancellationToken) throws -> PrescribedVoltageReduction.Lift {
        let matched = try payload.chart.evolutionPayload(record: record)
        let source = try matched.values.reconstructionPayload(record: record)
        let workspace = try source.reduction.makeWorkspace(plan: source.plan, cancellation: cancellation)
        return try source.reduction.lift(workspace: workspace,
            reducedCoordinates: payload.leftRates, sourceValues: matched.spatial.leftSlopes, cancellation: cancellation)
    }
    internal struct Payload: Sendable {
        let chart: NativePrescribedVoltageChart
        let chargeStateLipschitzUpperBound: Double
        let chargeRates: [CompensatedEnclosure]
        let leftRates: [CompensatedEnclosure]
        let rightRates: [CompensatedEnclosure]
        let leftCharge: [CompensatedEnclosure]
        let rightCharge: [CompensatedEnclosure]
        let branches: [Int]
        let left: PrescribedVoltageReduction.Application
        let right: PrescribedVoltageReduction.Application
        let lease: any Sendable
    }
}
