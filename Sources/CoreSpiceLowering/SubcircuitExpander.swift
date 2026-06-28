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

        try validateExecutableComponent(component, fullName: fullName)

        // Map component type to device type name
        let typeName = try mapComponentType(component.type, modelName: component.modelName)

        // Evaluate parameters: merge model parameters first, then override with instance parameters
        let resolver = ParameterExpressionResolver(context: context, randomUniform: randomUniform)
        let evaluator = ExpressionEvaluator(context: context, randomUniform: randomUniform)
        var evaluatedParams: [String: ParameterValue] = [:]

        // If expandModels is enabled and a model exists, copy model parameters as base
        if configuration.expandModels, let modelName = component.modelName,
           let model = context.model(modelName) {
            let modelParameters = try resolver.resolveInTemporaryScope(model.parameters)
            for (name, value) in modelParameters {
                evaluatedParams[name] = .real(value)
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
        for index in 0..<branchCount {
            let branchName = branchCount == 1 ? fullName : "\(fullName)#\(index)"
            _ = builder.branch(name: branchName)
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

        // Evaluate public parameters. Instance values override defaults before
        // evaluation, so dependent defaults see the same public-parameter set
        // the body will see.
        var publicParameterValues = subcircuit.parameters
        for (name, value) in component.parameters {
            publicParameterValues[name] = value
        }
        let instanceParams = try ParameterExpressionResolver(
            context: context,
            randomUniform: randomUniform
        ).resolveInTemporaryScope(publicParameterValues)

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
        let resolver = ParameterExpressionResolver(context: context, randomUniform: randomUniform)

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
                    try resolver.resolveIntoCurrentScope([name: .expression(expression)])
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

    private func validateExecutableComponent(
        _ component: ParsedComponent,
        fullName: String
    ) throws {
        if let reason = unsupportedComponentTypeReason(component.type) {
            throw LoweringError.invalidComponent(name: fullName, reason: reason)
        }

        guard component.type.requiresModelForNativeExecution else {
            return
        }
        guard let model = try resolvedModel(for: component) else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "Component requires a .model reference for native execution"
            )
        }
        guard component.type.accepts(model: model) else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "Referenced model '\(model.name)' has type \(model.type.rawValue), which does not match component type \(component.type.rawValue)"
            )
        }
        if let reason = unsupportedModelReason(model) {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "Referenced model '\(model.name)' is not executable: \(reason)"
            )
        }
    }

    private func resolvedModel(for component: ParsedComponent) throws -> ParsedModel? {
        guard let modelName = component.modelName else {
            return nil
        }
        guard let model = context.model(modelName) else {
            throw LoweringError.undefinedModel(name: modelName, location: component.location)
        }
        return model
    }

    private func unsupportedComponentTypeReason(_ type: ComponentType) -> String? {
        switch type {
        case .behavioral:
            return "Behavioral B-source execution is not implemented"
        case .jfet:
            return "JFET execution is not implemented"
        case .mesfet:
            return "MESFET execution is not implemented"
        case .transmissionLine:
            return "Transmission-line execution is not implemented"
        case .uniformRC:
            return "Uniform-RC execution is not implemented"
        case .coupledInductors:
            return "Mutual-inductor execution is not implemented"
        case .currentSwitch:
            return "Current-controlled switch execution is not implemented"
        default:
            return nil
        }
    }

    private func unsupportedModelReason(_ model: ParsedModel) -> String? {
        switch model.type {
        case .diode, .npn, .pnp:
            return nil
        case .nmos, .pmos:
            let level = model.level ?? 1
            switch level {
            case 1, 2, 3:
                return nil
            case 49:
                return "BSIM3 MOS level 49 execution is not implemented"
            case 54:
                return "BSIM4 MOS level 54 execution is not implemented"
            default:
                return "MOS level \(level) execution is not implemented"
            }
        case .njf, .pjf:
            return "JFET model execution is not implemented"
        case .nmf, .pmf:
            return "MESFET model execution is not implemented"
        case .ltra:
            return "LTRA model execution is not implemented"
        case .sw:
            return nil
        case .csw:
            return "Current-controlled switch model execution is not implemented"
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
            guard let name = modelName, let model = context.model(name) else {
                throw LoweringError.invalidComponent(
                    name: "",
                    reason: "BJT component requires a .model reference"
                )
            }
            return model.type == .npn ? "npn" : "pnp"
        case .jfet:
            if let name = modelName, let model = context.model(name) {
                return model.type == .njf ? "njfet" : "pjfet"
            }
            return "njfet"
        case .mosfet:
            guard let name = modelName, let model = context.model(name) else {
                throw LoweringError.invalidComponent(
                    name: "",
                    reason: "MOSFET component requires a .model reference"
                )
            }
            let prefix = model.type == .nmos ? "nmos" : "pmos"
            let level = model.level ?? 1
            return "\(prefix)_l\(level)"
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
            return "vswitch"
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

private extension ComponentType {
    var requiresModelForNativeExecution: Bool {
        switch self {
        case .diode, .bjt, .mosfet, .switch_:
            return true
        default:
            return false
        }
    }

    func accepts(model: ParsedModel) -> Bool {
        switch self {
        case .diode:
            return model.type == .diode
        case .bjt:
            return model.type == .npn || model.type == .pnp
        case .mosfet:
            return model.type == .nmos || model.type == .pmos
        case .jfet:
            return model.type == .njf || model.type == .pjf
        case .mesfet:
            return model.type == .nmf || model.type == .pmf
        case .switch_:
            return model.type == .sw
        case .currentSwitch:
            return model.type == .csw
        case .transmissionLine:
            return model.type == .ltra
        default:
            return true
        }
    }
}
