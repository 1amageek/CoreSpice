import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceDevices

/// Exclusive executable state; inspection records never expose device history.
public struct PreparedNativeSPICESimulation: ~Copyable, Sendable {
    public let record: SPICENativeSimulationRecord
    public var input: PreparedSPICESimulation { record.input }
    public var plan: ExecutionPlan { record.plan }
    public var limits: SPICENativeExecutionLimits { record.limits }
    public var configurationIdentity: ContentDigest { record.configurationIdentity }
    public var algorithmIdentity: String { record.algorithmIdentity }
    public var solverIdentity: String { record.solverIdentity }
    private let circuit: PreparedNativeCircuit

    internal init(record: SPICENativeSimulationRecord, circuit: consuming PreparedNativeCircuit) {
        self.record = record; self.circuit = circuit
    }

    internal consuming func takeCircuit() -> PreparedNativeCircuit { circuit }
}
