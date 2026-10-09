/// A circuit component as parsed from a netlist.
///
/// Components represent devices like resistors, capacitors, transistors, etc.
/// Each component has a name, type, connections, and parameters.
public struct ParsedComponent: Sendable, Hashable {

    /// The instance name (e.g., "R1", "M1").
    public let name: String

    /// The component type.
    public let type: ComponentType

    /// The nodes this component connects to.
    public let nodes: [ParsedNodeRef]

    /// The model name if this component uses a model.
    public let modelName: String?

    /// Ambiguous bare R/C source symbol awaiting scoped resolution; absent for explicit numeric syntax.
    public let passiveModelCandidate: String?

    /// Parameter values for this component.
    public let parameters: [String: ParsedParameterValue]

    /// The source location of this component definition.
    public let location: SourceLocation?
    public let origin: ParsedStatementOrigin?
    public let parameterAssignments: [ParsedParameterAssignment]

    public init(
        name: String,
        type: ComponentType,
        nodes: [ParsedNodeRef],
        modelName: String? = nil,
        passiveModelCandidate: String? = nil,
        parameters: [String: ParsedParameterValue] = [:],
        location: SourceLocation? = nil,
        origin: ParsedStatementOrigin? = nil,
        parameterAssignments: [ParsedParameterAssignment] = []
    ) {
        self.name = name
        self.type = type
        self.nodes = nodes
        self.modelName = modelName
        self.passiveModelCandidate = passiveModelCandidate
        self.parameters = parameters
        self.location = location
        self.origin = origin
        self.parameterAssignments = parameterAssignments
    }
}

extension ParsedComponent: CustomStringConvertible {
    public var description: String {
        var result = "\(name) \(nodes.map { $0.name }.joined(separator: " "))"
        if let model = modelName {
            result += " \(model)"
        } else if let candidate = passiveModelCandidate {
            result += " \(candidate)"
        }
        if !parameters.isEmpty {
            let primaryKey = type == .capacitor ? "c" : "r"
            let params = parameters.filter { name, value in
                guard let candidate = passiveModelCandidate else { return true }
                return name != primaryKey || value != .expression(.identifier(candidate))
            }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            if !params.isEmpty { result += " \(params)" }
        }
        return result
    }
}
