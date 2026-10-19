import CircuiteFoundation
import CoreSpiceIO
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import CoreSpiceEvent

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

    public func close() throws(OSDIAdapterFailure) { try circuit.close() }
    /// Uses the same actual bound-source inspection with this preparation's exact SPICE identities.
    public borrowing func withIndependentVoltageSources<Result>(cancellation: CancellationToken,
        _ body: (borrowing NativeVoltageSourceInspectionView) throws -> Result)
        throws(NativeVoltageSourceInspectionFailure) -> Result {
        try circuit.inspectIndependentVoltageSources(origin: .spice(sourceInputIdentity: input.sourceInputIdentity,
            sourceConfigurationIdentity: input.configuration.identity, nativeConfigurationIdentity: configurationIdentity),
            cancellation: cancellation, body)
    }
    internal consuming func takeCircuit() -> PreparedNativeCircuit { circuit }
}
