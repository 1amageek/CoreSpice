import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// A conditional initial-coordinate root and actual checked-box charge enclosure.
/// It establishes neither initial-set completeness nor a source history.
package final class NativePrescribedVoltageInitialRoot: Sendable {
    package let dimension: Int
    package let chargeCoordinateCount: Int
    package let algebraicCoordinateCount: Int
    package let normUpperBound: Double
    private let payload: Payload
    private init(_ payload: Payload) {
        self.payload = payload; dimension = payload.root.dimension
        chargeCoordinateCount = payload.dynamic.count; algebraicCoordinateCount = payload.algebraic.count
        normUpperBound = payload.root.normUpperBound
    }
    package func image(at row: Int) throws -> CompensatedEnclosure { try payload.root.image(at: row) }
    package func initialCharge(at index: Int) throws -> CompensatedEnclosure {
        guard payload.initialCharge.indices.contains(index) else { throw NativePrescribedVoltageChartFailure.invalidInput }
        return payload.initialCharge[index]
    }
    package func chargeReducedRow(at index: Int) throws -> Int {
        guard payload.dynamic.indices.contains(index) else { throw NativePrescribedVoltageChartFailure.invalidInput }
        return payload.dynamic[index]
    }
    package func algebraicReducedRow(at index: Int) throws -> Int {
        guard payload.algebraic.indices.contains(index) else { throw NativePrescribedVoltageChartFailure.invalidInput }
        return payload.algebraic[index]
    }
    internal func initialPayload(record: NativeCircuitPreparationRecord) throws -> Payload {
        guard let actual = record.constitutiveBacking?.control, actual === payload.control else {
            throw NativePrescribedVoltageChartFailure.wrongOwner
        }
        return payload
    }
    // Retain the checked initial root before querying charge on its full checked box.
    internal static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        values: NativePrescribedVoltageValues, algebraicRows: [Int], dynamicInitialCoordinates: [CompensatedEnclosure],
        center: [CompensatedValue], inverse: SparseStructure, inverseValues: [Double],
        capture: OSDIConstitutiveCaptureInputs?, range: OSDISmoothRangeCaptureInputs?,
        limits: NativePrescribedVoltageChartLimits, cancellation: CancellationToken) async throws -> Self {
        Self(try await NativePrescribedVoltageInitialRootAssembly.certify(record: record, devices: devices,
            values: values, algebraicRows: algebraicRows, dynamicInitialCoordinates: dynamicInitialCoordinates,
            center: center, inverse: inverse, inverseValues: inverseValues, capture: capture,
            range: range, limits: limits, cancellation: cancellation))
    }
    internal struct Payload: Sendable {
        let values: NativePrescribedVoltageValues
        let centerValues: NativePrescribedVoltageValues
        let checkedQValues: NativePrescribedVoltageValues
        let algebraic: [Int]
        let dynamic: [Int]
        let dynamicInitialCoordinates: [CompensatedEnclosure]
        let initialCharge: [CompensatedEnclosure]
        let center: [CompensatedValue]
        let control: NativeConstitutivePreparationControl
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
