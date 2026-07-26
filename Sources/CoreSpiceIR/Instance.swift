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

    /// MNA branch variables introduced by this instance.
    public let ownedBranches: [Branch]

    /// Existing MNA branches referenced by this instance.
    public let referencedBranches: [Branch]

    /// Circuit nodes read by the device but not exposed as device ports.
    public let referencedNodes: [Node]

    /// Optical nodes connected to this device (empty for purely electrical devices).
    public let opticalNodes: [OpticalNode]

    public init(
        name: String,
        typeName: String,
        nodes: [Node],
        parameters: [String: ParameterValue],
        ownedBranches: [Branch] = [],
        referencedBranches: [Branch] = [],
        referencedNodes: [Node] = [],
        opticalNodes: [OpticalNode] = []
    ) {
        self.name = name
        self.typeName = typeName
        self.nodes = nodes
        self.parameters = parameters
        self.ownedBranches = ownedBranches
        self.referencedBranches = referencedBranches
        self.referencedNodes = referencedNodes
        self.opticalNodes = opticalNodes
    }
}
