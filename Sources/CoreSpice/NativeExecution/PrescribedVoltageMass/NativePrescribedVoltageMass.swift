import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// Source-bound reduced coefficients, without root, flow or state-count authority.
package final class NativePrescribedVoltageMass: Sendable {
    package struct Regularity: Sendable {
        package let dimension: Int
        package let normUpperBound: Double
        private let owner: NativePrescribedVoltageMass
        fileprivate init(owner: NativePrescribedVoltageMass, fact: ValidatedMatrixRegularity.Result) {
            self.owner = owner; dimension = fact.dimension; normUpperBound = fact.normUpperBound
        }
    }
    package let dimension: Int
    private let payload: Payload
    private init(_ payload: Payload) { self.payload = payload; dimension = payload.pattern.dimension }
    internal static func assemble(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageMassLimits, cancellation: CancellationToken) async throws -> Self {
        Self(try await NativePrescribedVoltageMassAssembly.assemble(record: record, devices: devices,
            values: values, range: range, limits: limits, cancellation: cancellation))
    }
    package func withMatrix<Result>(_ body: (Int, Span<Int>, Span<Int>, Span<CompensatedEnclosure>) throws -> Result) rethrows -> Result {
        let pattern = payload.pattern
        let coefficients = payload.coefficients
        return try body(dimension, pattern.rowPointers.span, pattern.columnIndices.span, coefficients.span)
    }
    package func drift(at row: Int, side: NativePrescribedVoltageReconstruction.Side) throws -> CompensatedEnclosure {
        guard (0..<dimension).contains(row) else { throw NativePrescribedVoltageMassFailure.invalidInput }
        return (side == .left ? payload.leftDrift : payload.rightDrift)[row]
    }
    package func certifyRegularity(inverse: borrowing SparseStructure, inverseValues: borrowing Span<Double>,
        limits: ValidatedMatrixRegularity.Limits, cancellation: CancellationToken) throws -> Regularity {
        func check() throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try payload.control.checkpoint(workUnits: 0)
        }
        try check()
        guard dimension > 0 else { throw NativePrescribedVoltageMassFailure.emptyMass }
        let pattern = payload.pattern
        let coefficients = payload.coefficients
        let fact = try ValidatedMatrixRegularity.certify(matrix: pattern, values: coefficients.span,
            inverse: inverse, inverseValues: inverseValues, limits: limits, control: payload.control)
        try check()
        return Regularity(owner: self, fact: fact)
    }
    internal struct Payload: Sendable {
        let values: NativePrescribedVoltageValues
        let pattern: SparseStructure
        let coefficients: [CompensatedEnclosure]
        let leftDrift: [CompensatedEnclosure]
        let rightDrift: [CompensatedEnclosure]
        let scopes: [OSDISmoothRangeScope]
        let control: NativeConstitutivePreparationControl
        let lease: any Sendable
        let matrixLease: any Sendable
    }
}
