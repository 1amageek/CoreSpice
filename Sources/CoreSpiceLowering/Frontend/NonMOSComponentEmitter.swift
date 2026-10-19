import CoreSpiceParsedIR
import CoreSpiceIR
import CoreSpiceMOSContracts

/// Established non-MOS topology emission; all numeric inputs are already resolved.
struct NonMOSComponentEmitter {
    func emit(_ component: ParsedComponent, name: String, typeName: String,
        nodes: [String], parameters: [String: ParameterValue], model: ResolvedDeviceModel?,
        consumption: ModelConsumption, prefix: String, referencedNodes: [String],
        referencedBranches: [String], into builder: inout BoundedFrontendNetlist) throws {
        if component.type == .coupledInductors {
            var references: [ParsedNodeRef] = []
            try builder.storage.reserve(&references, nodes.count)
            for node in nodes { references.append(ParsedNodeRef(name: node)) }
            let mapped = ParsedComponent(name: component.name, type: component.type,
                nodes: references, parameters: component.parameters)
            try addMutualInductanceInstance(fullName: name, component: mapped, prefix: "", mapNames: false,
                parameters: parameters, into: &builder)
            return
        }
        if component.type == .jfet || component.type == .mesfet {
            try addSeriesResistanceFETInstances(fullName: name, typeName: typeName, nodeNames: nodes,
                parameters: parameters, familyName: component.type == .jfet ? "JFET" : "MESFET",
                modelConsumption: consumption, into: &builder)
            return
        }
        if component.type == .uniformRC {
            try UniformRCExpander().expand(name: name, nodeNames: nodes, parameters: parameters,
                modelConsumption: consumption, into: &builder)
            return
        }
        var privateNodes: [String] = []
        if component.type == .bjt {
            for (key, terminal) in [("rc", "collector"), ("rb", "base"), ("re", "emitter")] {
                let resistance = try realParameter(named: key, in: parameters, componentName: name) ?? 0
                guard resistance.isFinite, resistance >= 0 else {
                    throw LoweringError.invalidComponent(name: name, reason: "BJT \(key) must be finite and non-negative")
                }
                if resistance > 0 {
                    try builder.storage.reserve(&privateNodes, privateNodes.count + 1)
                    let privateName = "\(name)#\(terminal)"
                    try builder.storage.text(privateName)
                    privateNodes.append(privateName)
                }
            }
        }
        var owned: [Branch] = []
        for index in 0..<Self.branchesRequired(for: typeName) {
            try builder.storage.reserve(&owned, owned.count + 1)
            owned.append(try builder.branch(name: Self.branchesRequired(for: typeName) == 1 ? name : "\(name)#\(index)"))
        }
        var reads = try referencedBranchNames(typeName: typeName, parameters: parameters, instanceName: name)
        try builder.storage.retain(reads)
        try builder.storage.reserve(&reads, reads.count + referencedBranches.count)
        reads.append(contentsOf: referencedBranches)
        try builder.addInstance(name: name, typeName: typeName, nodes: nodes, parameters: parameters,
            model: model, modelConsumption: consumption, ownedBranches: owned, ownedNodeNames: privateNodes,
            referencedBranchNames: reads, referencedNodeNames: referencedNodes)
    }
    private func addSeriesResistanceFETInstances(
        fullName: String,
        typeName: String,
        nodeNames: [String],
        parameters: [String: ParameterValue],
        familyName: String,
        modelConsumption: ModelConsumption,
        into builder: inout BoundedFrontendNetlist
    ) throws {
        guard nodeNames.count == 3 else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "\(familyName) component requires drain, gate, and source nodes"
            )
        }

        let drainResistance = try realParameter(named: "rd", in: parameters, componentName: fullName) ?? 0.0
        let sourceResistance = try realParameter(named: "rs", in: parameters, componentName: fullName) ?? 0.0
        let area = try realParameter(named: "area", in: parameters, componentName: fullName) ?? 1.0
        let multiplier = try realParameter(named: "m", in: parameters, componentName: fullName) ?? 1.0
        let scale = area * multiplier
        guard drainResistance >= 0 else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "\(familyName) rd must be non-negative"
            )
        }
        guard sourceResistance >= 0 else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "\(familyName) rs must be non-negative"
            )
        }
        guard scale.isFinite, scale > 0 else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "\(familyName) area and multiplier must produce a positive finite scale"
            )
        }

        try builder.storage.budget.add(MOSStorageBudget.capacityBytes(parameters.capacity, of: (String, ParameterValue).self))
        var coreParameters = parameters
        coreParameters.removeValue(forKey: "rd")
        coreParameters.removeValue(forKey: "rs")

        var coreDrain = nodeNames[0]
        let gate = nodeNames[1]
        var coreSource = nodeNames[2]

        if drainResistance > 0 {
            coreDrain = "\(fullName)#drain"
            try builder.addInstance(
                name: "\(fullName).rd",
                typeName: "resistor",
                nodes: [nodeNames[0], coreDrain],
                parameters: ["r": .real(drainResistance / scale)],
                modelConsumption: modelConsumption
            )
        }

        if sourceResistance > 0 {
            coreSource = "\(fullName)#source"
            try builder.addInstance(
                name: "\(fullName).rs",
                typeName: "resistor",
                nodes: [nodeNames[2], coreSource],
                parameters: ["r": .real(sourceResistance / scale)],
                modelConsumption: modelConsumption
            )
        }

        try builder.addInstance(
            name: fullName,
            typeName: typeName,
            nodes: [coreDrain, gate, coreSource],
            parameters: coreParameters,
            modelConsumption: modelConsumption
        )
    }

    private func addMutualInductanceInstance(
        fullName: String,
        component: ParsedComponent,
        prefix: String,
        mapNames: Bool,
        parameters: [String: ParameterValue],
        into builder: inout BoundedFrontendNetlist
    ) throws {
        guard component.nodes.count == 2 else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "Mutual-inductor component requires two inductor references"
            )
        }

        guard parameters["k"] != nil else {
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "Mutual-inductor component requires a coupling coefficient"
            )
        }

        var mutualParameters: [String: ParameterValue] = [:]
        try builder.storage.reserve(&mutualParameters, parameters.count + 2)
        for (key, value) in parameters { mutualParameters[key] = value }
        mutualParameters["inductor_a"] = .string(
            lowerBranchReferenceName(component.nodes[0].name, prefix: prefix, mapNames: mapNames)
        )
        mutualParameters["inductor_b"] = .string(
            lowerBranchReferenceName(component.nodes[1].name, prefix: prefix, mapNames: mapNames)
        )

        let referencedBranchNames = try [
            "inductor_a",
            "inductor_b",
        ].map { parameterName -> String in
            guard case .string(let branchName) = mutualParameters[parameterName] else {
                throw LoweringError.invalidComponent(
                    name: fullName,
                    reason: "Could not resolve \(parameterName) branch reference"
                )
            }
            return branchName
        }

        try builder.addInstance(
            name: fullName,
            typeName: "mutual",
            nodes: [],
            parameters: mutualParameters,
            modelConsumption: .modelFree,
            referencedBranchNames: referencedBranchNames
        )
    }

    private func referencedBranchNames(
        typeName: String,
        parameters: [String: ParameterValue],
        instanceName: String
    ) throws -> [String] {
        let parameterNames: [String]
        switch typeName {
        case "cccs_ref", "ccvs_ref", "cswitch_ref":
            parameterNames = ["control_source"]
        default:
            parameterNames = []
        }

        return try parameterNames.map { parameterName in
            guard case .string(let branchName) = parameters[parameterName] else {
                throw LoweringError.invalidComponent(
                    name: instanceName,
                    reason: "Could not resolve \(parameterName) branch reference"
                )
            }
            return branchName
        }
    }

    private func lowerBranchReferenceName(_ name: String, prefix: String, mapNames: Bool) -> String {
        if !mapNames || prefix.isEmpty || name.contains(".") {
            return name
        }
        return "\(prefix).\(name)"
    }

    private func realParameter(
        named name: String,
        in parameters: [String: ParameterValue],
        componentName: String
    ) throws -> Double? {
        guard let value = parameters[name] else { return nil }
        guard case .real(let real) = value else {
            throw LoweringError.invalidComponent(
                name: componentName,
                reason: "Parameter '\(name)' must be real"
            )
        }
        return real
    }

    static func branchesRequired(for typeName: String) -> Int {
        switch typeName {
        case "vsource":  return 1  // Independent voltage source
        case "inductor":  return 1  // Inductor (short at DC, jωL at AC)
        case "vcvs":      return 1  // Voltage-controlled voltage source
        case "cccs":      return 1  // Current-controlled current source (sensing branch)
        case "ccvs":      return 2  // Current-controlled voltage source (sensing + output)
        case "ccvs_ref":  return 1  // Current-controlled voltage source output branch
        case "cswitch":   return 1  // Current-controlled switch sensing branch
        case "tline":     return 2  // One current variable for each transmission-line port
        case "behavioral_vsource": return 1
        default:          return 0
        }
    }

    func lowerControlSourceParameter(
        _ value: ParsedParameterValue,
        fullName: String,
        prefix: String
    ) throws -> ParameterValue {
        let sourceName: String
        switch value {
        case .string(let text):
            sourceName = text
        case .expression(.identifier(let text)):
            sourceName = text
        default:
            throw LoweringError.invalidComponent(
                name: fullName,
                reason: "Current-controlled source reference must be a source name"
            )
        }

        let resolvedName: String
        if prefix.isEmpty || sourceName.contains(".") {
            resolvedName = sourceName
        } else {
            resolvedName = "\(prefix).\(sourceName)"
        }
        return .string(resolvedName)
    }

    func unsupportedComponentParameterReason(_ component: ParsedComponent) -> String? {
        switch component.type {
        case .behavioral:
            let outputCount = (component.parameters["v"] == nil ? 0 : 1) + (component.parameters["i"] == nil ? 0 : 1)
            guard outputCount == 1, component.parameters.count == 1 else {
                return "Behavioral source requires exactly one V={...} or I={...} output expression"
            }
            guard let output = component.parameters[component.parameters["v"] == nil ? "i" : "v"],
                  case .expression = output else {
                return "Behavioral source output must be a braced expression"
            }
            return nil
        case .jfet:
            let supported = Set(["area"])
            if let unsupported = component.parameters.keys.first(where: { !supported.contains($0) }) {
                return "JFET instance parameter '\(unsupported)' execution is not implemented"
            }
            return nil
        case .mesfet:
            let supported = Set(["area", "m"])
            if let unsupported = component.parameters.keys.first(where: { !supported.contains($0) }) {
                return "MESFET instance parameter '\(unsupported)' execution is not implemented"
            }
            return nil
        case .transmissionLine:
            let supported = Set(["z0", "td", "f", "nl"])
            if let unsupported = component.parameters.keys.first(where: { !supported.contains($0) }) {
                return "Transmission-line instance parameter '\(unsupported)' execution is not implemented"
            }
            return nil
        default:
            return nil
        }
    }

    func unsupportedModelReason(_ model: ParsedModel) -> String? {
        switch model.type {
        case .osdi:
            return "OSDI requires its dedicated typed emission path"
        case .capacitor:
            return model.level == nil ? nil : "Capacitor model level is outside the admitted static profile"
        case .npn, .pnp:
            return model.level == nil || model.level == 1 ? nil : "BJT model level is outside the admitted low-injection GP profile"
        case .resistor, .diode:
            return nil
        case .nmos, .pmos:
            let level = model.level ?? 1
            switch level {
            case 1, 2, 3:
                return nil
            case 49:
                return nil
            case 54:
                return nil
            default:
                return "MOS level \(level) execution is not implemented"
            }
        case .njf, .pjf:
            return unsupportedJFETModelParameterReason(model)
        case .nmf, .pmf:
            return unsupportedMESFETModelParameterReason(model)
        case .ltra:
            return "LTRA model execution is not implemented"
        case .urc:
            return nil
        case .sw, .csw:
            return nil
        }
    }

    func unsupportedJFETModelParameterReason(_ model: ParsedModel) -> String? {
        let supported = Set([
            "vto", "beta", "b", "lambda", "is", "n", "cgs", "cgd", "pb", "m",
            "fc", "kf", "af", "area", "tnom", "tnom_k", "rd", "rs"
        ])
        if let unsupported = model.parameters.keys.first(where: { !supported.contains($0) }) {
            return "JFET model parameter '\(unsupported)' execution is not implemented"
        }
        return nil
    }

    func unsupportedMESFETModelParameterReason(_ model: ParsedModel) -> String? {
        let supported = Set([
            "vto", "alpha", "beta", "lambda", "b", "rd", "rs", "cgs", "cgd",
            "pb", "is", "fc", "kf", "af", "area", "m", "tnom", "tnom_k",
        ])
        if let unsupported = model.parameters.keys.first(where: { !supported.contains($0) }) {
            return "MESFET model parameter '\(unsupported)' execution is not implemented"
        }
        return nil
    }

}
