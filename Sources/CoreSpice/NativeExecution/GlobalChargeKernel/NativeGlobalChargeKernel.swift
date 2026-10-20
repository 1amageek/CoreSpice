import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI
import OSDIContracts

/// Complete constant-left Q kernel on one fixed actual-preparation constitutive domain.
package final class NativeGlobalChargeKernel: Sendable {
    package enum RankWitness: Sendable, Equatable {
        case fullNullspace
        case regularMinor(normUpperBound: Double)
    }
    package let dimension: Int
    package let chargeSpanDimension: Int
    package let nullRows: ExactRowAlgebra.Rows
    package let rankWitness: RankWitness
    private let payload: Payload

    private init(_ payload: Payload) {
        self.payload = payload
        dimension = payload.preparation.plan.topology.dimension
        nullRows = payload.rows
        chargeSpanDimension = dimension - nullRows.rowCount
        rankWitness = payload.witness
    }
    internal static func certify(record: NativeCircuitPreparationRecord, devices: [any BoundDevice],
        domain: NativeGlobalChargeDomain, proposal: NativeGlobalChargeProposal,
        capture: OSDIConstitutiveCaptureInputs?, limits: NativeGlobalChargeLimits,
        cancellation: CancellationToken) async throws -> NativeGlobalChargeKernel {
        let payload = try await NativeGlobalChargeAssembly.check(record: record, devices: devices,
            domain: domain, proposal: proposal, capture: capture, limits: limits, cancellation: cancellation)
        return NativeGlobalChargeKernel(payload)
    }

    package func anchorCharge(row: Int, anchor: Int) throws -> CompensatedEnclosure {
        guard row >= 0, row < dimension, anchor >= 0, anchor < chargeSpanDimension else {
            throw NativeGlobalChargeFailure.invalidInput
        }
        return payload.charges[anchor * dimension + row]
    }
    package var sourceInputCount: Int { payload.localProofs.count }

    internal struct NativeTerm: Sendable {
        let row: Int
        let column: Int
        let bits: UInt64
        let coefficient: ExactRowAlgebra.Scalar
    }
    internal struct LocalProof: Sendable {
        let retention: OSDIConstitutiveCaptureRetention
        let rows: ExactRowAlgebra.Rows
        let lower: [CompensatedValue]
        let upper: [CompensatedValue]
        let lowerContext: OSDIPrecisionContext
        let upperContext: OSDIPrecisionContext
        let usedPrecisionBits: UInt32
        let anchorPrecisionBits: [UInt32]
    }
    internal struct Payload: Sendable {
        let preparation: NativeCircuitPreparationRecord
        let domain: NativeGlobalChargeDomain
        let anchors: [NativeGlobalChargeAnchor]
        let rows: ExactRowAlgebra.Rows
        let completion: ExactRowAlgebra.CompletionResult
        let nativeTerms: [NativeTerm]
        let localProofs: [LocalProof]
        let charges: [CompensatedEnclosure]
        let minor: [CompensatedEnclosure]
        let inverse: SparseStructure
        let inverseValues: [Double]
        let witness: RankWitness
        let lease: any Sendable
    }
}
