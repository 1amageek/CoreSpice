import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceOSDI
import CoreSpiceParsedIR
import CoreSpiceEvent

/// A single-use native circuit; only concrete analysis operations can consume its devices.
public struct PreparedNativeCircuit: ~Copyable, Sendable {
    public let record: NativeCircuitPreparationRecord
    public var plan: ExecutionPlan { record.plan }
    private let devices: [any BoundDevice]
    internal init(record: NativeCircuitPreparationRecord, devices: [any BoundDevice]) {
        self.record = record; self.devices = devices
    }
    public func close() throws(OSDIAdapterFailure) { try record.osdiLifetime?.close() }
    /// Borrows actual checked native source values without consuming or closing this circuit.
    public borrowing func withIndependentVoltageSources<Result>(cancellation: CancellationToken,
        _ body: (borrowing NativeVoltageSourceInspectionView) throws -> Result)
        throws(NativeVoltageSourceInspectionFailure) -> Result {
        try inspectIndependentVoltageSources(origin: .circuit, cancellation: cancellation, body)
    }
    internal borrowing func inspectIndependentVoltageSources<Result>(origin: NativeVoltageSourceInspectionOrigin,
        cancellation: CancellationToken, _ body: (borrowing NativeVoltageSourceInspectionView) throws -> Result)
        throws(NativeVoltageSourceInspectionFailure) -> Result {
        try NativeVoltageSourceInspection.inspect(record: record, devices: devices, origin: origin,
            cancellation: cancellation, body)
    }
    /// Shares invocation-wide numerical counters while preserving this circuit's fixed limits and layout.
    public consuming func usingExecutionResources(_ resources: AnalysisExecutionResources) throws -> Self {
        Self(record: try record.usingExecutionResources(resources), devices: devices)
    }
    internal consuming func addingRetainedStorage(byteCount: UInt64, reservation: SPICESourceStorageReservation) throws -> Self {
        Self(record: try record.addingRetainedStorage(byteCount: byteCount, reservation: reservation), devices: devices)
    }
    internal consuming func takeState() -> (NativeCircuitPreparationRecord, [any BoundDevice]) { (record, devices) }
}
