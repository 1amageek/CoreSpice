import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// Both one-sided conditional full-row reconstructions; no root or flow certificate.
package final class NativePrescribedVoltageReconstruction: Sendable {
    package enum Side: Sendable, Equatable { case left, right }
    package let dimension: Int
    package let reducedCoordinateCount: Int
    private let payload: Payload
    private init(_ payload: Payload) {
        self.payload = payload; dimension = payload.values.dimension
        reducedCoordinateCount = payload.values.reducedCoordinateCount
    }
    internal static func reconstruct(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, leftReducedRates: [CompensatedEnclosure],
        rightReducedRates: [CompensatedEnclosure], range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageReconstructionLimits, cancellation: CancellationToken) async throws -> Self {
        Self(try await NativePrescribedVoltageRateAssembly.reconstruct(record: record, devices: devices,
            values: values, leftReducedRates: leftReducedRates, rightReducedRates: rightReducedRates,
            range: range, limits: limits, cancellation: cancellation))
    }
    private func application(_ side: Side) -> PrescribedVoltageReduction.Application {
        side == .left ? payload.left : payload.right
    }
    package func coordinate(at row: Int, side: Side) throws -> CompensatedEnclosure {
        try application(side).coordinate(at: row)
    }
    package func originalResidual(at row: Int, side: Side) throws -> CompensatedEnclosure {
        try application(side).originalResidual(at: row)
    }
    package func reducedResidual(at row: Int, side: Side) throws -> CompensatedEnclosure {
        try application(side).reducedResidual(at: row)
    }
    package func stateChargeRate(at row: Int, side: Side) throws -> CompensatedEnclosure {
        guard (0..<dimension).contains(row) else { throw NativePrescribedVoltageReconstructionFailure.invalidInput }
        return (side == .left ? payload.stateLeft : payload.stateRight)[row]
    }
    package func prescribedChargeRate(at row: Int, side: Side) throws -> CompensatedEnclosure {
        guard (0..<dimension).contains(row) else { throw NativePrescribedVoltageReconstructionFailure.invalidInput }
        return (side == .left ? payload.inputLeft : payload.inputRight)[row]
    }
    internal struct Payload: Sendable {
        let values: NativePrescribedVoltageValues
        let leftRates: [CompensatedEnclosure]
        let rightRates: [CompensatedEnclosure]
        let leftSlopes: [CompensatedEnclosure]
        let rightSlopes: [CompensatedEnclosure]
        let stateLeft: [CompensatedEnclosure]
        let stateRight: [CompensatedEnclosure]
        let inputLeft: [CompensatedEnclosure]
        let inputRight: [CompensatedEnclosure]
        let left: PrescribedVoltageReduction.Application
        let right: PrescribedVoltageReduction.Application
        let scopes: [OSDISmoothRangeScope]
        let lease: any Sendable
    }
}
