import CoreSpiceParsedIR
import CoreSpiceIR

/// Lowers a parsed netlist to CircuitIR.
///
/// The lowering process evaluates expressions, expands subcircuits,
/// and resolves model references to produce a flat circuit representation.
public struct NetlistLowering: Sendable {

    /// Configuration for the lowering process.
    public struct Configuration: Sendable {

        /// Maximum subcircuit expansion depth.
        public var maxExpansionDepth: Int

        /// Whether to flatten all subcircuits.
        /// When true, subcircuits are expanded inline.
        /// When false, subcircuit structure is preserved for hierarchical netlists.
        public var flattenSubcircuits: Bool

        /// Whether to expand models inline.
        /// When true, model parameters are copied to each device instance.
        /// When false, devices maintain references to model definitions.
        public var expandModels: Bool

        /// Whether to evaluate expressions at lowering time.
        /// When true, all parameter expressions are evaluated to constants.
        /// When false, symbolic expressions are preserved where possible.
        /// Note: CircuitIR requires concrete values, so expressions are always
        /// evaluated in practice, but this flag controls whether evaluation
        /// errors are raised or deferred.
        public var evaluateExpressions: Bool

        /// Default temperature in Celsius.
        public var temperature: Double

        /// Parameter overrides applied globally.
        /// These values override any parameters defined in the netlist.
        public var parameterOverrides: [String: Double]

        public init(
            maxExpansionDepth: Int = 64,
            flattenSubcircuits: Bool = true,
            expandModels: Bool = true,
            evaluateExpressions: Bool = true,
            temperature: Double = 27.0,
            parameterOverrides: [String: Double] = [:]
        ) {
            self.maxExpansionDepth = maxExpansionDepth
            self.flattenSubcircuits = flattenSubcircuits
            self.expandModels = expandModels
            self.evaluateExpressions = evaluateExpressions
            self.temperature = temperature
            self.parameterOverrides = parameterOverrides
        }

        /// Default configuration for circuit simulation.
        public static let `default` = Configuration()

        /// Configuration that preserves hierarchy for schematic export.
        /// Subcircuits are not flattened and models are not expanded.
        public static let preserveHierarchy = Configuration(
            flattenSubcircuits: false,
            expandModels: false,
            evaluateExpressions: true
        )
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Lowers a parsed netlist to CircuitIR.
    public func lower(_ netlist: ParsedNetlist) throws -> CircuitIR {
        let context = LoweringContext(maxDepth: configuration.maxExpansionDepth)
        context.temperature = configuration.temperature

        // Register models and subcircuits
        for model in netlist.models {
            context.registerModel(model)
        }
        for subcircuit in netlist.subcircuits {
            context.registerSubcircuit(subcircuit)
        }

        // Evaluate global parameters
        let evaluator = ExpressionEvaluator(context: context)
        if configuration.evaluateExpressions {
            for (name, expr) in netlist.parameters {
                let value = try evaluator.evaluate(expr)
                context.setParameter(name, value: value)
            }
        }

        // Apply parameter overrides (these take precedence over netlist parameters)
        for (name, value) in configuration.parameterOverrides {
            context.setParameter(name, value: value)
        }

        // Build the netlist
        var builder = Netlist()

        // Expand components
        let expander = SubcircuitExpander(context: context, configuration: configuration)
        for component in netlist.components {
            try expander.expandComponent(component, into: &builder, prefix: "")
        }

        return try builder.build()
    }
}

/// The result of lowering a netlist.
public struct LoweringResult: Sendable {

    /// The lowered circuit IR.
    public let circuit: CircuitIR

    /// Any warnings generated during lowering.
    public let warnings: [String]

    /// The evaluated parameter values.
    public let parameters: [String: Double]

    public init(
        circuit: CircuitIR,
        warnings: [String] = [],
        parameters: [String: Double] = [:]
    ) {
        self.circuit = circuit
        self.warnings = warnings
        self.parameters = parameters
    }
}
