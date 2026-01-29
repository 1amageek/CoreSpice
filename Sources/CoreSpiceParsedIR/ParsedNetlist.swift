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

    /// Global parameter definitions.
    public let parameters: [String: ParsedExpression]

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
        parameters: [String: ParsedExpression] = [:],
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
        self.parameters = parameters
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
            parameters: parameters
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

        if !parameters.isEmpty {
            for (name, expr) in parameters.sorted(by: { $0.key < $1.key }) {
                lines.append(".param \(name) = \(expr)")
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
