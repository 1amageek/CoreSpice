/// A subcircuit definition from the netlist.
///
/// Subcircuits are reusable circuit blocks that can be instantiated
/// multiple times with different parameter values.
public struct ParsedSubcircuit: Sendable, Hashable {

    /// The subcircuit name used for instantiation.
    public let name: String

    /// The external port names.
    public let ports: [String]

    /// Default parameter values for this subcircuit.
    public let parameters: [String: ParsedParameterValue]

    /// The subcircuit body containing components, models, and nested subcircuits.
    public let body: ParsedNetlistBody

    /// The source location of this subcircuit definition.
    public let location: SourceLocation?

    public init(
        name: String,
        ports: [String],
        parameters: [String: ParsedParameterValue] = [:],
        body: ParsedNetlistBody,
        location: SourceLocation? = nil
    ) {
        self.name = name
        self.ports = ports
        self.parameters = parameters
        self.body = body
        self.location = location
    }
}

/// The body content of a netlist or subcircuit.
///
/// Separating the body allows for recursive subcircuit definitions.
public struct ParsedNetlistBody: Sendable, Hashable {

    /// Components in this body.
    public let components: [ParsedComponent]

    /// Models defined in this body.
    public let models: [ParsedModel]

    /// Nested subcircuit definitions.
    public let subcircuits: [ParsedSubcircuit]

    /// Local parameter definitions.
    public let parameters: [String: ParsedExpression]

    /// Source-level local parameter declarations in body order.
    public let parameterDefinitions: [ParsedParameterDefinition]

    public init(
        components: [ParsedComponent] = [],
        models: [ParsedModel] = [],
        subcircuits: [ParsedSubcircuit] = [],
        parameters: [String: ParsedExpression] = [:],
        parameterDefinitions: [ParsedParameterDefinition] = []
    ) {
        self.components = components
        self.models = models
        self.subcircuits = subcircuits
        self.parameters = parameters
        self.parameterDefinitions = parameterDefinitions
    }

    /// An empty body.
    public static let empty = ParsedNetlistBody()
}

extension ParsedSubcircuit: CustomStringConvertible {
    public var description: String {
        var result = ".subckt \(name) \(ports.joined(separator: " "))"
        if !parameters.isEmpty {
            result += " params:"
            result += parameters.map { " \($0.key)=\($0.value)" }.joined()
        }
        return result
    }
}
