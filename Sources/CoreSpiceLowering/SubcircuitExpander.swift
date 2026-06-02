import CoreSpiceParsedIR
import CoreSpiceIR

/// Expands subcircuit instances into their component parts.
public struct SubcircuitExpander: Sendable {

    private let context: LoweringContext
    private let configuration: NetlistLowering.Configuration
    private let randomUniform: @Sendable () -> Double

    public init(
        context: LoweringContext,
        configuration: NetlistLowering.Configuration,
        randomUniform: @escaping @Sendable () -> Double
    ) {
        self.context = context
        self.configuration = configuration
        self.randomUniform = randomUniform
    }

    /// Expands a component into the netlist builder.
    ///
    /// - Parameter mapNodes: When true, node names are prefixed with `prefix`
    ///   (used for top-level components). When false, the node names are already
    ///   final (a subcircuit instance has already resolved its ports to external
    ///   nodes and its internals to prefixed names), so they are used as-is. This
    ///   prevents the ports from being prefixed a second time.
    public func expandComponent(
        _ component: ParsedComponent,
        into builder: inout Netlist,
        prefix: String,
        mapNodes: Bool = true
    ) throws {
        let fullName = prefix.isEmpty ? component.name : "\(prefix).\(component.name)"

        // Handle subcircuit instances specially
        if component.type == .subcircuitInstance {
            try expandSubcircuitInstance(component, into: &builder, prefix: prefix)
            return
        }

        // Map component type to device type name
        let typeName = try mapComponentType(component.type, modelName: component.modelName)

        // Evaluate parameters: merge model parameters first, then override with instance parameters
        let evaluator = ExpressionEvaluator(context: context, randomUniform: randomUniform)
        var evaluatedParams: [String: ParameterValue] = [:]

        // If expandModels is enabled and a model exists, copy model parameters as base
        if configuration.expandModels, let modelName = component.modelName,
           let model = context.model(modelName) {
            for (name, value) in model.parameters {
                let evaluated = try evaluator.evaluate(value)
                evaluatedParams[name] = .real(evaluated)
            }
        }

        // Instance parameters override model parameters
        for (name, value) in component.parameters {
            let evaluated = try evaluator.evaluate(value)
            evaluatedParams[name] = .real(evaluated)
        }

        // Map nodes. When the caller has already resolved node names (subcircuit
        // body expansion), use them as-is to avoid prefixing the ports twice.
        let nodeNames: [String]
        if mapNodes {
            nodeNames = component.nodes.map { node -> String in
                if prefix.isEmpty {
                    return node.name
                }
                // Keep global nodes as-is
                if node.isGround {
                    return node.name
                }
                return "\(prefix).\(node.name)"
            }
        } else {
            nodeNames = component.nodes.map { $0.name }
        }

        // Allocate branches for devices that need them (voltage sources, inductors, etc.)
        let branchCount = Self.branchesRequired(for: typeName)
        for _ in 0..<branchCount {
            _ = builder.branch()
        }

        // Add the instance
        try builder.addInstance(
            name: fullName,
            typeName: typeName,
            nodes: nodeNames,
            parameters: evaluatedParams
        )
    }

    /// Expands a subcircuit instance.
    private func expandSubcircuitInstance(
        _ component: ParsedComponent,
        into builder: inout Netlist,
        prefix: String
    ) throws {
        guard let subcircuitName = component.modelName else {
            throw LoweringError.invalidComponent(
                name: component.name,
                reason: "Subcircuit instance missing subcircuit name"
            )
        }

        guard let subcircuit = context.subcircuit(subcircuitName) else {
            throw LoweringError.undefinedSubcircuit(
                name: subcircuitName,
                location: component.location
            )
        }

        // Check port count
        guard component.nodes.count == subcircuit.ports.count else {
            throw LoweringError.portCountMismatch(
                subcircuit: subcircuitName,
                expected: subcircuit.ports.count,
                got: component.nodes.count
            )
        }

        // Create instance prefix
        let instancePrefix = prefix.isEmpty ? component.name : "\(prefix).\(component.name)"

        // Evaluate instance parameters
        let evaluator = ExpressionEvaluator(context: context, randomUniform: randomUniform)
        var instanceParams: [String: Double] = [:]

        // Start with subcircuit defaults
        for (name, value) in subcircuit.parameters {
            instanceParams[name] = try evaluator.evaluate(value)
        }

        // Override with instance parameters
        for (name, value) in component.parameters {
            instanceParams[name] = try evaluator.evaluate(value)
        }

        // Create port mapping
        var portMapping: [String: String] = [:]
        for (port, node) in zip(subcircuit.ports, component.nodes) {
            let externalNode: String
            if node.isGround {
                externalNode = node.name
            } else if prefix.isEmpty {
                externalNode = node.name
            } else {
                externalNode = "\(prefix).\(node.name)"
            }
            portMapping[port] = externalNode
        }

        let publicParameterNames = Set(instanceParams.keys.map { $0.lowercased() })

        // Expand subcircuit body with new scope
        try context.withScope(parameters: instanceParams) {
            for model in subcircuit.body.models {
                try context.registerScopedModel(model)
            }
            try applyBodyParameters(
                subcircuit.body.parameters,
                subcircuitName: subcircuit.name,
                protectedNames: publicParameterNames
            )
            for bodyComponent in subcircuit.body.components {
                // Map component nodes through port mapping or to internal nodes
                var mappedComponent = bodyComponent
                let mappedNodes = bodyComponent.nodes.map { node -> ParsedNodeRef in
                    if let external = portMapping[node.name] {
                        return ParsedNodeRef(name: external, location: node.location)
                    }
                    if node.isGround {
                        return node
                    }
                    return ParsedNodeRef(
                        name: "\(instancePrefix).\(node.name)",
                        location: node.location
                    )
                }

                mappedComponent = ParsedComponent(
                    name: bodyComponent.name,
                    type: bodyComponent.type,
                    nodes: mappedNodes,
                    modelName: bodyComponent.modelName,
                    parameters: bodyComponent.parameters,
                    location: bodyComponent.location
                )

                // Nodes are already resolved (ports -> external, internals ->
                // prefixed), so do not prefix them again.
                try expandComponent(mappedComponent, into: &builder, prefix: instancePrefix, mapNodes: false)
            }
        }
    }

    private func applyBodyParameters(
        _ parameters: [String: ParsedExpression],
        subcircuitName: String,
        protectedNames: Set<String>
    ) throws {
        var pending = parameters
        var lastFailure: Error?
        let evaluator = ExpressionEvaluator(context: context, randomUniform: randomUniform)

        while !pending.isEmpty {
            var progressed = false

            for name in pending.keys.sorted() {
                let lowered = name.lowercased()
                if protectedNames.contains(lowered) {
                    throw LoweringError.invalidComponent(
                        name: subcircuitName,
                        reason: "Local parameter '\(name)' conflicts with a public subcircuit parameter"
                    )
                }

                guard let expression = pending[name] else {
                    continue
                }

                do {
                    let value = try evaluator.evaluate(expression)
                    try context.setScopedParameter(name, value: value)
                    pending.removeValue(forKey: name)
                    progressed = true
                } catch {
                    lastFailure = error
                }
            }

            if !progressed {
                if let lastFailure {
                    throw lastFailure
                }
                throw LoweringError.expressionEvaluationFailed(
                    expression: subcircuitName,
                    reason: "Could not resolve local subcircuit parameters"
                )
            }
        }
    }

    /// Returns the number of MNA branch variables required by a device type.
    ///
    /// Devices that impose voltage constraints (voltage sources, inductors,
    /// controlled sources with voltage outputs) need branch current variables.
    private static func branchesRequired(for typeName: String) -> Int {
        switch typeName {
        case "vsource":  return 1  // Independent voltage source
        case "inductor":  return 1  // Inductor (short at DC, jωL at AC)
        case "vcvs":      return 1  // Voltage-controlled voltage source
        case "cccs":      return 1  // Current-controlled current source (sensing branch)
        case "ccvs":      return 2  // Current-controlled voltage source (sensing + output)
        default:          return 0
        }
    }

    /// Maps a component type to a device type name.
    private func mapComponentType(
        _ type: ComponentType,
        modelName: String?
    ) throws -> String {
        switch type {
        case .resistor:
            return "resistor"
        case .capacitor:
            return "capacitor"
        case .inductor:
            return "inductor"
        case .voltageSource:
            return "vsource"
        case .currentSource:
            return "isource"
        case .vcvs:
            return "vcvs"
        case .vccs:
            return "vccs"
        case .cccs:
            return "cccs"
        case .ccvs:
            return "ccvs"
        case .diode:
            return "diode"
        case .bjt:
            // Determine NPN or PNP from model
            if let name = modelName, let model = context.model(name) {
                return model.type == .npn ? "npn" : "pnp"
            }
            return "npn"
        case .jfet:
            if let name = modelName, let model = context.model(name) {
                return model.type == .njf ? "njfet" : "pjfet"
            }
            return "njfet"
        case .mosfet:
            if let name = modelName, let model = context.model(name) {
                let prefix = model.type == .nmos ? "nmos" : "pmos"
                let level = model.level ?? 1
                return "\(prefix)_l\(level)"
            }
            return "nmos_l1"
        case .mesfet:
            return "mesfet"
        case .transmissionLine:
            return "tline"
        case .uniformRC:
            return "urc"
        case .coupledInductors:
            return "mutual"
        case .behavioral:
            return "behavioral"
        case .switch_:
            return "switch"
        case .currentSwitch:
            return "cswitch"
        case .subcircuitInstance:
            throw LoweringError.invalidComponent(
                name: "",
                reason: "Subcircuit instances should be expanded, not mapped"
            )
        }
    }
}
