/// A connection between a device's optical port and an optical node.
///
/// Records which optical port of which device instance is connected
/// to which optical node in the circuit, enabling the compiler to
/// build the optical signal propagation DAG.
public struct OpticalConnection: Sendable {

    /// The name of the device instance.
    public let instanceName: String

    /// The name of the optical port on the device.
    public let portName: String

    /// The optical node this port connects to.
    public let opticalNode: OpticalNode

    public init(instanceName: String, portName: String, opticalNode: OpticalNode) {
        self.instanceName = instanceName
        self.portName = portName
        self.opticalNode = opticalNode
    }
}
