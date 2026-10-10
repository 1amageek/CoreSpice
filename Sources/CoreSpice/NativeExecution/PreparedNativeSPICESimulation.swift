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
    private let devices: [any BoundDevice]

    internal init(record: SPICENativeSimulationRecord, devices: [any BoundDevice]) {
        self.record = record; self.devices = devices
    }

    internal consuming func takeExecutionState() -> (SPICENativeSimulationRecord, [any BoundDevice]) {
        (record, devices)
    }
}
