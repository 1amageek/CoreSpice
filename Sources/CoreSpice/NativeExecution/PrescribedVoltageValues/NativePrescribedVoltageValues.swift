import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// Conditional F0/Q values on a correlated prescribed-source image; no physical current output.
package final class NativePrescribedVoltageValues: Sendable {
    package let dimension: Int
    package let reducedCoordinateCount: Int
    package let selectedSourceCount: Int
    package let capturedSourceCount: Int
    private let payload: Payload
    private init(_ payload: Payload) {
        self.payload = payload; dimension = payload.lower.count
        reducedCoordinateCount = payload.plan.reducedCount; selectedSourceCount = payload.sources.count
        capturedSourceCount = payload.captures.count
    }
    internal static func enclose(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        originalDomain: NativeGlobalChargeDomain, sources: [NativePrescribedVoltageSource],
        reducedCoordinates: [CompensatedEnclosure], capture: OSDIConstitutiveCaptureInputs?,
        limits: NativePrescribedVoltageLimits, cancellation: CancellationToken) async throws -> Self {
        Self(try await NativePrescribedVoltageAssembly.enclose(record: record, devices: devices,
            domain: originalDomain, sources: sources, reduced: reducedCoordinates, capture: capture,
            limits: limits, cancellation: cancellation))
    }
    internal func reconstructionPayload(record: NativeCircuitPreparationRecord) throws -> Payload {
        guard let original = payload.preparation.constitutiveBacking?.control,
              let actual = record.constitutiveBacking?.control, original === actual else {
            throw NativePrescribedVoltageReconstructionFailure.wrongOwner
        }
        return payload
    }
    private func check(_ row: Int) throws {
        guard (0..<dimension).contains(row) else { throw NativePrescribedVoltageFailure.invalidInput }
    }
    package func coordinateLower(at row: Int) throws -> CompensatedValue { try check(row); return payload.lower[row] }
    package func coordinateUpper(at row: Int) throws -> CompensatedValue { try check(row); return payload.upper[row] }
    package func staticResidual(at row: Int) throws -> CompensatedEnclosure { try check(row); return payload.f[row] }
    package func charge(at row: Int) throws -> CompensatedEnclosure { try check(row); return payload.q[row] }
    package func sourceVoltage(at index: Int) throws -> CompensatedEnclosure {
        guard payload.voltages.indices.contains(index) else { throw NativePrescribedVoltageFailure.invalidInput }
        return payload.voltages[index]
    }
    internal struct Payload: Sendable {
        let preparation: NativeCircuitPreparationRecord
        let originalDomain: NativeGlobalChargeDomain
        let sources: [NativePrescribedVoltageSource]
        let laws: [BoundPrescribedVoltageLaw]
        let unselected: [IndependentVoltageSourceFact]
        let terms: [ContinuousEquationLinearTerm]
        let reduction: PrescribedVoltageReduction
        let reducedCoordinates: [CompensatedEnclosure]
        let plan: PrescribedVoltageReduction.Plan
        let lift: PrescribedVoltageReduction.Lift
        let lower: [CompensatedValue]
        let upper: [CompensatedValue]
        let voltages: [CompensatedEnclosure]
        let f: [CompensatedEnclosure]
        let q: [CompensatedEnclosure]
        let captures: [OSDIConstitutiveCaptureRetention]
        let lease: any Sendable
    }
}
