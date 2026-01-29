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
    public func expandComponent(
        _ component: ParsedComponent,
        into builder: inout Netlist,
        prefix: String
    ) throws {
        let fullName = prefix.isEmpty ? component.name : "\(prefix).\(component.name)"

        // Handle subcircuit instances specially
        if component.type == .subcircuitInstance {
            try expandSubcircuitInstance(component, into: &builder, prefix: prefix)
            return
        }

        // Map component type to device type name
        let typeName = try mapComponentType(component.type, modelName: component.modelName)

        // Evaluate parameters
        let evaluator = ExpressionEvaluator(context: context, randomUniform: randomUniform)
        var evaluatedParams: [String: ParameterValue] = [:]
        for (name, value) in component.parameters {
            let evaluated = try evaluator.evaluate(value)
            evaluatedParams[name] = .real(evaluated)
        }

        // Map nodes
        let nodeNames = component.nodes.map { node -> String in
            if prefix.isEmpty {
                return node.name
            }
            // Keep global nodes as-is
            if node.isGround {
                return node.name
            }
            return "\(prefix).\(node.name)"
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

        // Expand subcircuit body with new scope
        try context.withScope(parameters: instanceParams) {
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

                try expandComponent(mappedComponent, into: &builder, prefix: instancePrefix)
            }
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
                return model.type == .nmos ? "nmos" : "pmos"
            }
            return "nmos"
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
