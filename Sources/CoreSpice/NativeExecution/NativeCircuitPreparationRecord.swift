import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceMOSContracts
import CoreSpiceParsedIR
import CoreSpiceOSDI
import CoreSpiceDiodeContracts

/// Immutable evidence without prepared executable device owners; retains caller-supplied acquisition inputs for fresh setup.
public struct NativeCircuitPreparationRecord: Sendable {
    public let executionResources: AnalysisExecutionResources?
    public let plan: ExecutionPlan
    public let operatingConditions: OperatingConditions
    public let limits: SPICENativeExecutionLimits
    public let numericalLimits: TransientExecutionLimits
    public let osdiPreparationRecords: [NativeOSDIPreparationRecord]
    public let osdiRuntimeInputs: SPICEOSDIRuntimeInputs?
    public let osdiVariableKinds: [MNAVariable: OSDIVariableKind]
    internal let osdiLifetime: OSDIExecutionLifetime?
    public let diodePreparationReceipts: [DiodePreparationReceipt]
    public let mosPreparationReceipts: [MOSPreparationReceipt]
    internal let resources: any SPICESourceResourceAccounting
    internal let compileCapacity: UInt64
    internal let reservations: [SPICESourceStorageReservation]

    /// Value-only evidence retains IR/compiler/metadata admission while releasing closed foreign execution owners.
    internal func valueEvidence() throws -> Self {
        guard osdiLifetime != nil else { return self }
        // NativeCircuitPreparer stores IR/setup, compiler and immutable metadata before foreign/validation owners.
        let retained = Array(reservations.prefix(3))
        var bytes: UInt64 = 0
        for reservation in retained { bytes = try NativeCircuitExecution.capacitySum(bytes, reservation.byteCount) }
        return Self(executionResources: executionResources, plan: plan, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, osdiPreparationRecords: osdiPreparationRecords,
            osdiRuntimeInputs: osdiRuntimeInputs, osdiVariableKinds: osdiVariableKinds, osdiLifetime: nil,
            diodePreparationReceipts: diodePreparationReceipts, mosPreparationReceipts: mosPreparationReceipts,
            resources: resources,
            compileCapacity: bytes, reservations: retained)
    }

    internal func usingExecutionResources(_ resources: AnalysisExecutionResources) throws -> Self {
        guard resources.limits == numericalLimits else { throw SPICENativePreparationError.invalidLimits }
        return Self(executionResources: resources, plan: plan, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, osdiPreparationRecords: osdiPreparationRecords,
            osdiRuntimeInputs: osdiRuntimeInputs, osdiVariableKinds: osdiVariableKinds, osdiLifetime: osdiLifetime,
            diodePreparationReceipts: diodePreparationReceipts, mosPreparationReceipts: mosPreparationReceipts,
            resources: self.resources,
            compileCapacity: compileCapacity, reservations: reservations)
    }

    internal func addingRetainedStorage(byteCount: UInt64, reservation: SPICESourceStorageReservation) throws -> Self {
        let (capacity, overflow) = compileCapacity.addingReportingOverflow(byteCount)
        guard !overflow, capacity <= limits.maximumAllocationBytes, reservation.byteCount == byteCount,
              reservation.kind == .liveOwnedBytes else {
            throw SPICENativePreparationError.capacityExceeded
        }
        return Self(executionResources: executionResources, plan: plan, operatingConditions: operatingConditions, limits: limits, numericalLimits: numericalLimits,
            osdiPreparationRecords: osdiPreparationRecords, osdiRuntimeInputs: osdiRuntimeInputs, osdiVariableKinds: osdiVariableKinds,
            osdiLifetime: osdiLifetime, diodePreparationReceipts: diodePreparationReceipts, mosPreparationReceipts: mosPreparationReceipts,
            resources: resources, compileCapacity: capacity,
            reservations: reservations + [reservation])
    }
}
