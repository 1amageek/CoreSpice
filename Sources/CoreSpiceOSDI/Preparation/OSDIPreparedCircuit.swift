import CoreSpiceIR
import CoreSpiceOSDIContracts

public struct OSDIPreparedCircuit: ~Copyable, Sendable {
    public let circuit: CircuitIR
    public let receipts: [OSDIPreparationReceipt]
    public let variableKinds: [MNAVariable: OSDIVariableKind]
    public let lifetime: OSDIExecutionLifetime
    private var devices: UniqueArray<OSDIPreparedDevice?>

    package init(circuit: CircuitIR, receipts: [OSDIPreparationReceipt],
        variableKinds: [MNAVariable: OSDIVariableKind], lifetime: OSDIExecutionLifetime,
        devices: consuming UniqueArray<OSDIPreparedDevice?>) {
        self.circuit = circuit; self.receipts = receipts; self.variableKinds = variableKinds
        self.lifetime = lifetime; self.devices = consume devices
    }
    /// The index is the original full circuit instance index; ordinary devices return nil.
    public mutating func takeDevice(at index: Int) throws(OSDIAdapterFailure) -> OSDIPreparedDevice? {
        guard (0..<devices.count).contains(index) else { throw .invalidTopology }
        return devices[index].take()
    }
    public func close() throws(OSDIAdapterFailure) { try lifetime.close() }
}
