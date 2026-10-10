import CoreSpiceCompile
import CoreSpiceDevices

/// A single-use native circuit; only concrete analysis operations can consume its devices.
public struct PreparedNativeCircuit: ~Copyable, Sendable {
    public let record: NativeCircuitPreparationRecord
    public var plan: ExecutionPlan { record.plan }
    private let devices: [any BoundDevice]
    internal init(record: NativeCircuitPreparationRecord, devices: [any BoundDevice]) {
        self.record = record; self.devices = devices
    }
    internal consuming func takeState() -> (NativeCircuitPreparationRecord, [any BoundDevice]) { (record, devices) }
}
