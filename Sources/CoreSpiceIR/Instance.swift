/// A placed device instance in the circuit.
///
/// Each instance references a device type by name, connects to
/// specific circuit nodes, and carries parameter values that
/// configure its behavior.
public struct Instance: Sendable {

    public let name: String
    public let typeName: String
    public let nodes: [Node]
    public let parameters: [String: ParameterValue]

    /// Optical nodes connected to this device (empty for purely electrical devices).
    public let opticalNodes: [OpticalNode]

    public init(
        name: String,
        typeName: String,
        nodes: [Node],
        parameters: [String: ParameterValue],
        opticalNodes: [OpticalNode] = []
    ) {
        self.name = name
        self.typeName = typeName
        self.nodes = nodes
        self.parameters = parameters
        self.opticalNodes = opticalNodes
    }
}
