import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Copyable evidence and rerun inputs, without executable device owners.
public struct SPICENativeSimulationRecord: Sendable {
    public let input: PreparedSPICESimulation
    public let circuitPreparation: NativeCircuitPreparationRecord
    public var plan: ExecutionPlan { circuitPreparation.plan }
    public var limits: SPICENativeExecutionLimits { circuitPreparation.limits }
    public let configurationIdentity: ContentDigest
    public let algorithmIdentity: String
    public let solverIdentity: String
    public var mosPreparationReceipts: [MOSPreparationReceipt] { circuitPreparation.mosPreparationReceipts }
    package var compileCapacity: UInt64 { circuitPreparation.compileCapacity }

    internal init(input: PreparedSPICESimulation, circuitPreparation: NativeCircuitPreparationRecord,
                  configurationIdentity: ContentDigest) {
        self.input = input; self.circuitPreparation = circuitPreparation
        self.configurationIdentity = configurationIdentity
        algorithmIdentity = "CoreSpice.NativeCPU.op-dc-tran.v1"
        solverIdentity = "CoreSpice.SparseLU.Accelerate.v1"
    }
}
