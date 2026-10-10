import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Copyable evidence and rerun inputs, without executable device owners.
public struct SPICENativeSimulationRecord: Sendable {
    public let input: PreparedSPICESimulation
    public let plan: ExecutionPlan
    public let limits: SPICENativeExecutionLimits
    public let configurationIdentity: ContentDigest
    public let algorithmIdentity: String
    public let solverIdentity: String
    public let mosPreparationReceipts: [MOSPreparationReceipt]
    package let executionCapacity: UInt64
    private let reservation: SPICESourceStorageReservation

    internal init(input: PreparedSPICESimulation, plan: ExecutionPlan, limits: SPICENativeExecutionLimits,
                  configurationIdentity: ContentDigest, executionCapacity: UInt64,
                  mosPreparationReceipts: [MOSPreparationReceipt], reservation: SPICESourceStorageReservation) {
        self.input = input; self.plan = plan; self.limits = limits; self.configurationIdentity = configurationIdentity
        self.executionCapacity = executionCapacity; self.reservation = reservation
        self.mosPreparationReceipts = mosPreparationReceipts
        algorithmIdentity = "CoreSpice.NativeCPU.op-dc-tran.v1"
        solverIdentity = "CoreSpice.SparseLU.Accelerate.v1"
    }
}
