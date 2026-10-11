import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Immutable preparation evidence with no executable authority.
public struct NativeCircuitPreparationRecord: Sendable {
    public let plan: ExecutionPlan
    public let operatingConditions: OperatingConditions
    public let limits: SPICENativeExecutionLimits
    public let numericalLimits: TransientExecutionLimits
    public let mosPreparationReceipts: [MOSPreparationReceipt]
    public let bsim45Models: [NativeBSIM45PreparationRecord]
    public let bsim4Models: [NativeBSIM4PreparationRecord]
    internal let resources: any SPICESourceResourceAccounting
    internal let compileCapacity: UInt64
    internal let reservations: [SPICESourceStorageReservation]
}
