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
    internal let constitutiveBacking: NativeConstitutivePreparationBacking?

    internal init(executionResources: AnalysisExecutionResources?, plan: ExecutionPlan,
        operatingConditions: OperatingConditions, limits: SPICENativeExecutionLimits,
        numericalLimits: TransientExecutionLimits, osdiPreparationRecords: [NativeOSDIPreparationRecord],
        osdiRuntimeInputs: SPICEOSDIRuntimeInputs?, osdiVariableKinds: [MNAVariable: OSDIVariableKind],
        osdiLifetime: OSDIExecutionLifetime?, diodePreparationReceipts: [DiodePreparationReceipt],
        mosPreparationReceipts: [MOSPreparationReceipt], resources: any SPICESourceResourceAccounting,
        compileCapacity: UInt64, reservations: [SPICESourceStorageReservation],
        constitutiveBacking: NativeConstitutivePreparationBacking? = nil) {
        self.executionResources = executionResources; self.plan = plan; self.operatingConditions = operatingConditions
        self.limits = limits; self.numericalLimits = numericalLimits; self.osdiPreparationRecords = osdiPreparationRecords
        self.osdiRuntimeInputs = osdiRuntimeInputs; self.osdiVariableKinds = osdiVariableKinds; self.osdiLifetime = osdiLifetime
        self.diodePreparationReceipts = diodePreparationReceipts; self.mosPreparationReceipts = mosPreparationReceipts
        self.resources = resources; self.compileCapacity = compileCapacity; self.reservations = reservations
        self.constitutiveBacking = constitutiveBacking
    }

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
            compileCapacity: constitutiveBacking == nil ? bytes : compileCapacity, reservations: retained,
            constitutiveBacking: constitutiveBacking)
    }

    internal func usingExecutionResources(_ resources: AnalysisExecutionResources) throws -> Self {
        guard resources.limits == numericalLimits else { throw SPICENativePreparationError.invalidLimits }
        return Self(executionResources: resources, plan: plan, operatingConditions: operatingConditions,
            limits: limits, numericalLimits: numericalLimits, osdiPreparationRecords: osdiPreparationRecords,
            osdiRuntimeInputs: osdiRuntimeInputs, osdiVariableKinds: osdiVariableKinds, osdiLifetime: osdiLifetime,
            diodePreparationReceipts: diodePreparationReceipts, mosPreparationReceipts: mosPreparationReceipts,
            resources: self.resources,
            compileCapacity: compileCapacity, reservations: reservations, constitutiveBacking: constitutiveBacking)
    }

    /// Acquires the exact lease before the caller constructs its retained metadata.
    internal func reservingRetainedStorage(byteCount: UInt64) throws -> Self {
        let capacity: UInt64
        let reservation: SPICESourceStorageReservation
        if let control = constitutiveBacking?.control {
            // The old array is retained in the floor; reserve both new concatenation payloads before copying.
            let count = try NativeCircuitExecution.capacitySum(UInt64(reservations.count), 2)
            let arrayBytes = try NativeCircuitExecution.capacitySum(
                NativeCircuitExecution.capacityProduct(count, UInt64(MemoryLayout<SPICESourceStorageReservation>.stride)),
                UInt64(2 * MemoryLayout<[SPICESourceStorageReservation]>.stride))
            guard let work = Int(exactly: count) else { throw SPICENativePreparationError.capacityExceeded }
            try control.checkpoint(workUnits: work)
            let admitted = try control.reserveRetainedFloor(byteCount: byteCount, metadataByteCount: arrayBytes)
            capacity = admitted.capacity; reservation = admitted.reservation
        } else {
            let (next, overflow) = compileCapacity.addingReportingOverflow(byteCount)
            guard !overflow, next <= limits.maximumAllocationBytes else {
                throw SPICENativePreparationError.capacityExceeded
            }
            reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: byteCount)
            capacity = next
        }
        return Self(executionResources: executionResources, plan: plan, operatingConditions: operatingConditions, limits: limits, numericalLimits: numericalLimits,
            osdiPreparationRecords: osdiPreparationRecords, osdiRuntimeInputs: osdiRuntimeInputs, osdiVariableKinds: osdiVariableKinds,
            osdiLifetime: osdiLifetime, diodePreparationReceipts: diodePreparationReceipts, mosPreparationReceipts: mosPreparationReceipts,
            resources: resources, compileCapacity: capacity,
            reservations: reservations + [reservation], constitutiveBacking: constitutiveBacking)
    }
}
