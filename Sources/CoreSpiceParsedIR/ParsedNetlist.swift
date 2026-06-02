/// A complete parsed netlist representing the top-level circuit.
///
/// The parsed netlist contains all elements from the source file
/// before lowering to the simulation IR.
public struct ParsedNetlist: Sendable, Hashable {

    /// The title of the netlist (from the first line).
    public let title: String?

    /// Top-level components.
    public let components: [ParsedComponent]

    /// Top-level model definitions.
    public let models: [ParsedModel]

    /// Subcircuit definitions.
    public let subcircuits: [ParsedSubcircuit]

    /// Analysis commands.
    public let analyses: [ParsedAnalysisCommand]

    /// Control statements.
    public let controls: [ParsedControlStatement]

    /// Source-level global parameter declarations in deck order.
    public let parameterDefinitions: [ParsedParameterDefinition]

    /// Global parameter definitions.
    public let parameters: [String: ParsedExpression]

    /// Source-level preprocessing evidence.
    public let preprocessingEvents: [SPICEPreprocessingEvent]

    /// Initial conditions for nodes.
    public let initialConditions: [String: ParsedParameterValue]

    /// Node set (initial guess) values.
    public let nodeSets: [String: ParsedParameterValue]

    /// Global nodes.
    public let globalNodes: [String]

    /// PVT corners defined in this netlist.
    public let pvtCorners: [PVTCorner]

    /// Monte Carlo variations.
    public let mcVariations: [MCVariation]

    /// The source file path if known.
    public let sourcePath: String?

    public init(
        title: String? = nil,
        components: [ParsedComponent] = [],
        models: [ParsedModel] = [],
        subcircuits: [ParsedSubcircuit] = [],
        analyses: [ParsedAnalysisCommand] = [],
        controls: [ParsedControlStatement] = [],
        parameterDefinitions: [ParsedParameterDefinition] = [],
        parameters: [String: ParsedExpression] = [:],
        preprocessingEvents: [SPICEPreprocessingEvent] = [],
        initialConditions: [String: ParsedParameterValue] = [:],
        nodeSets: [String: ParsedParameterValue] = [:],
        globalNodes: [String] = [],
        pvtCorners: [PVTCorner] = [],
        mcVariations: [MCVariation] = [],
        sourcePath: String? = nil
    ) {
        self.title = title
        self.components = components
        self.models = models
        self.subcircuits = subcircuits
        self.analyses = analyses
        self.controls = controls
        self.parameterDefinitions = parameterDefinitions
        self.parameters = parameters
        self.preprocessingEvents = preprocessingEvents
        self.initialConditions = initialConditions
        self.nodeSets = nodeSets
        self.globalNodes = globalNodes
        self.pvtCorners = pvtCorners
        self.mcVariations = mcVariations
        self.sourcePath = sourcePath
    }

    /// Creates an empty netlist.
    public static let empty = ParsedNetlist()

    /// Returns the body representation of this netlist.
    public var body: ParsedNetlistBody {
        ParsedNetlistBody(
            components: components,
            models: models,
            subcircuits: subcircuits,
            parameters: parameters,
            parameterDefinitions: parameterDefinitions
        )
    }

    /// Finds a subcircuit definition by name.
    public func subcircuit(named name: String) -> ParsedSubcircuit? {
        subcircuits.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Finds a model definition by name.
    public func model(named name: String) -> ParsedModel? {
        models.first { $0.name.lowercased() == name.lowercased() }
    }
}

extension ParsedNetlist: CustomStringConvertible {
    public var description: String {
        var lines: [String] = []

        if let t = title {
            lines.append(t)
        } else {
            lines.append("* Untitled netlist")
        }

        if !parameterDefinitions.isEmpty {
            for definition in parameterDefinitions {
                lines.append(".param \(definition.name) = \(definition.value)")
            }
        } else if !parameters.isEmpty {
            for (name, expression) in parameters.sorted(by: { $0.key < $1.key }) {
                lines.append(".param \(name) = \(expression)")
            }
        }

        for model in models {
            lines.append(model.description)
        }

        for subckt in subcircuits {
            lines.append(subckt.description)
            lines.append(".ends \(subckt.name)")
        }

        for component in components {
            lines.append(component.description)
        }

        for control in controls {
            lines.append(String(describing: control))
        }

        lines.append(".end")

        return lines.joined(separator: "\n")
    }
}
