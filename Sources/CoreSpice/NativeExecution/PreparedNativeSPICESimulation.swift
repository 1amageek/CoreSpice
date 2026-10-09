import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceParsedIR

public struct PreparedNativeSPICESimulation: Sendable {
    public let input: PreparedSPICESimulation
    public let plan: ExecutionPlan
    public let limits: SPICENativeExecutionLimits
    public let configurationIdentity: ContentDigest
    public let algorithmIdentity: String
    public let solverIdentity: String
    package let executionCapacity: UInt64
    private let reservation: SPICESourceStorageReservation
    internal init(input: PreparedSPICESimulation, plan: ExecutionPlan, limits: SPICENativeExecutionLimits,
                  configurationIdentity: ContentDigest, executionCapacity: UInt64,
                  reservation: SPICESourceStorageReservation) {
        self.input = input; self.plan = plan; self.limits = limits; self.configurationIdentity = configurationIdentity
        self.executionCapacity = executionCapacity; self.reservation = reservation
        algorithmIdentity = "CoreSpice.NativeCPU.op-dc-tran.v1"
        solverIdentity = "CoreSpice.SparseLU.Accelerate.v1"
    }
}
