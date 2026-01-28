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

    public init(
        name: String,
        typeName: String,
        nodes: [Node],
        parameters: [String: ParameterValue]
    ) {
        self.name = name
        self.typeName = typeName
        self.nodes = nodes
        self.parameters = parameters
    }
}
