import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// One source-bound conditional coordinate charge chart, without flow/history authority.
package final class NativePrescribedVoltageChart: Sendable {
    package let dimension: Int
    package let chargeCoordinateCount: Int
    package let algebraicCoordinateCount: Int
    package let sourceInputCount: Int
    package let normUpperBound: Double
    private let payload: Payload
    private init(_ payload: Payload) {
        self.payload = payload; dimension = payload.root.dimension
        chargeCoordinateCount = payload.dynamic.count; algebraicCoordinateCount = payload.algebraic.count
        sourceInputCount = payload.identities.count; normUpperBound = payload.root.normUpperBound
    }
    package func image(at row: Int) throws -> CompensatedEnclosure { try payload.root.image(at: row) }
    package func algebraicReducedRow(at index: Int) throws -> Int {
        guard payload.algebraic.indices.contains(index) else { throw NativePrescribedVoltageChartFailure.invalidInput }
        return payload.algebraic[index]
    }
    package func chargeReducedRow(at index: Int) throws -> Int {
        guard payload.dynamic.indices.contains(index) else { throw NativePrescribedVoltageChartFailure.invalidInput }
        return payload.dynamic[index]
    }
    internal func evolutionPayload(record: NativeCircuitPreparationRecord) throws -> Payload {
        guard let actual = record.constitutiveBacking?.control, actual === payload.control else {
            throw NativePrescribedVoltageEvolutionFailure.wrongOwner
        }
        return payload
    }
    internal static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, algebraicRows: [Int], chargeParameters: [CompensatedEnclosure],
        center: [CompensatedValue], inverse: SparseStructure, inverseValues: [Double],
        capture: OSDIConstitutiveCaptureInputs?, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageChartLimits, cancellation: CancellationToken) async throws -> Self {
        Self(try await NativePrescribedVoltageChartAssembly.certify(record: record, devices: devices,
            values: values, algebraicRows: algebraicRows, chargeParameters: chargeParameters, center: center,
            inverse: inverse, inverseValues: inverseValues, capture: capture, range: range, limits: limits,
            cancellation: cancellation))
    }
    internal struct Payload: Sendable {
        let values: NativePrescribedVoltageValues
        let centerValues: NativePrescribedVoltageValues
        let algebraic: [Int]
        let dynamic: [Int]
        let chargeParameters: [CompensatedEnclosure]
        let center: [CompensatedValue]
        let control: NativeConstitutivePreparationControl
        let spatial: NativePrescribedVoltageChartSpatialData
        let checkedCoordinates: [CompensatedEnclosure]
        let checkedLower: [CompensatedValue]
        let checkedUpper: [CompensatedValue]
        let jacobian: SparseStructure
        let jacobianValues: [CompensatedEnclosure]
        let inverse: SparseStructure
        let inverseValues: [Double]
        let centerResidual: [CompensatedEnclosure]
        let identities: [NativeGlobalChargeKernel.LocalProof]
        let smooth: [OSDISmoothRangeScope]
        let root: ValidatedParametricRoot.Result
        let lease: any Sendable
    }
}
