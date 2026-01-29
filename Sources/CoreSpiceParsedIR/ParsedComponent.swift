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

    /// Parameter values for this component.
    public let parameters: [String: ParsedParameterValue]

    /// The source location of this component definition.
    public let location: SourceLocation?

    public init(
        name: String,
        type: ComponentType,
        nodes: [ParsedNodeRef],
        modelName: String? = nil,
        parameters: [String: ParsedParameterValue] = [:],
        location: SourceLocation? = nil
    ) {
        self.name = name
        self.type = type
        self.nodes = nodes
        self.modelName = modelName
        self.parameters = parameters
        self.location = location
    }
}

extension ParsedComponent: CustomStringConvertible {
    public var description: String {
        var result = "\(name) \(nodes.map { $0.name }.joined(separator: " "))"
        if let model = modelName {
            result += " \(model)"
        }
        if !parameters.isEmpty {
            let params = parameters.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            result += " \(params)"
        }
        return result
    }
}
