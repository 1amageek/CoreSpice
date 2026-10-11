import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

struct NetlistInvocationPlanner {
    let compiled: CompiledNetlist
    let limits: MOSResolutionLimits
    let control: (any MOSResolutionControlling)?
    let storage: FrontendStorage
    private var invocations: [MOSScopeInvocation] = []
    private var multipliedScopes: [Bool] = []
    private var jobs: [FrontendExecutionJob] = []

    init(compiled: CompiledNetlist, limits: MOSResolutionLimits, control: (any MOSResolutionControlling)?) throws {
        self.compiled = compiled; self.limits = limits; self.control = control
        storage = FrontendStorage(limits: limits, control: control)
        try storage.budget.add(compiled.retainedBytes)
    }
    mutating func plan(overrides: [String: Double], profile: MOSInputProfile) throws -> FrontendPlan {
        if profile == .pinnedNgspiceNormalV1, let multiplier = compiled.hierarchicalMultiplier {
            try planMultiplicity(multiplier)
        }
        var actuals: [MOSInvocationActual] = []
        for (name, value) in try storage.entries(overrides) {
            guard let symbol = compiled.snapshot.symbol(named: name.lowercased()) else {
                throw MOSResolutionFailure.invalidIdentifier(name)
            }
            try storage.reserve(&actuals, actuals.count + 1)
            actuals.append(try MOSInvocationActual(symbol: symbol, constant: value, limits: limits))
        }
        try visit(scope: MOSScopeID(0), caller: nil, actuals: actuals, source: nil,
            prefix: "", ports: [:], depth: 1)
        // Activation scratch does not belong to the published session's retained storage.
        storage.budget.release(try MOSStorageBudget.capacityBytes(multipliedScopes.capacity, of: Bool.self))
        multipliedScopes = []
        let graph = try MOSInvocationGraph(snapshot: compiled.snapshot, invocations: invocations,
            limits: limits, control: control)
        return FrontendPlan(graph: graph, jobs: jobs, storage: storage)
    }
    private mutating func visit(scope: MOSScopeID, caller: UInt64?, actuals: [MOSInvocationActual],
        source: MOSSourceOccurrence?, prefix: String, ports: [String: String], depth: Int) throws {
        try storage.spend()
        guard depth <= limits.maximumScopeDepth else { throw MOSResolutionFailure.limitExceeded(.scopeDepth) }
        guard invocations.count < limits.maximumInvocations else { throw MOSResolutionFailure.limitExceeded(.invocations) }
        let id = UInt64(invocations.count)
        let multiplier = multipliedScopes.isEmpty || !multipliedScopes[Int(scope.rawValue)]
            ? nil : compiled.hierarchicalMultiplier
        var effectiveActuals = actuals
        if let multiplier, !actuals.contains(where: { $0.symbol == multiplier.symbol }) {
            try storage.retain(actuals)
            try storage.reserve(&effectiveActuals, effectiveActuals.count + 1)
            effectiveActuals.append(try .init(symbol: multiplier.symbol, constant: 1, limits: limits))
        }
        let invocation = try MOSScopeInvocation(id: id, scope: scope, callerInvocationID: caller,
            actuals: effectiveActuals, source: source, limits: limits)
        try storage.reserve(&invocations, invocations.count + 1); invocations.append(invocation)
        try storage.reserve(&jobs, jobs.count + 1); jobs.append(.enter(id))
        let body = compiled.scopes[Int(scope.rawValue)]
        for template in body.components {
            try storage.spend()
            let component = template.component
            let fullName = prefix.isEmpty ? component.name : prefix + "." + component.name
            try storage.text(fullName)
            var nodes: [String] = []
            for node in component.nodes {
                let mapped: String
                if let external = ports[node.name] { mapped = external }
                else if node.isGround || prefix.isEmpty { mapped = node.name }
                else { mapped = prefix + "." + node.name }
                try storage.text(mapped); try storage.reserve(&nodes, nodes.count + 1); nodes.append(mapped)
            }
            if component.type == .subcircuitInstance {
                guard let name = component.modelName, let target = try lookup(name, scope: scope),
                      let declaration = compiled.scopes[Int(target.rawValue)].subcircuit else {
                    throw LoweringError.undefinedSubcircuit(name: component.modelName ?? component.name, location: component.location)
                }
                guard nodes.count == declaration.ports.count else {
                    throw LoweringError.portCountMismatch(subcircuit: declaration.name,
                        expected: declaration.ports.count, got: nodes.count)
                }
                var actuals: [MOSInvocationActual] = []
                let propagated = inheritsMultiplier(template.component) ? multiplier : nil
                for binding in template.assignments {
                    if binding.symbol == propagated?.symbol { continue }
                    try storage.reserve(&actuals, actuals.count + 1)
                    actuals.append(try .init(symbol: binding.symbol, program: binding.program,
                        source: frontendSource(component.origin, location: component.location), limits: limits))
                }
                if let propagated {
                    var acceptsMultiplier = multipliedScopes[Int(target.rawValue)]
                    for binding in try compiled.snapshot.scope(target).parameterBindings {
                        try storage.spend()
                        if try compiled.snapshot.binding(binding).symbol == propagated.symbol { acceptsMultiplier = true }
                    }
                    // FIXME(INCOMPLETE_IMPLEMENTATION): The pinned source's implicit nested rewrite is order-dependent.
                    // Reachable X planning refuses an undeclared child multiplier instead of inventing recursive semantics.
                    // Admit only after ordered preprocessing occurrences and the fixed reference rejection/success cases agree.
                    guard acceptsMultiplier else {
                        throw LoweringError.unsupportedFeature(feature: "Implicit nested subcircuit multiplicity is outside pinned ordinary MOS scope")
                    }
                    try storage.reserve(&actuals, actuals.count + 1)
                    actuals.append(try .init(symbol: propagated.symbol, program: propagated.program, limits: limits))
                }
                guard template.assignments.count == component.parameters.count, component.parameterAssignments.allSatisfy({ $0.additionalValues.isEmpty }) else {
                    throw LoweringError.invalidComponent(name: fullName, reason: "Subcircuit actuals must be unique scalar assignments")
                }
                var mapping: [String: String] = [:]
                for (port, external) in zip(declaration.ports, nodes) {
                    try storage.reserve(&mapping, mapping.count + 1); mapping[port] = external
                }
                try visit(scope: target, caller: id, actuals: actuals,
                    source: frontendSource(component.origin, location: component.location),
                    prefix: fullName, ports: mapping, depth: depth + 1)
            } else {
                try storage.reserve(&jobs, jobs.count + 1)
                jobs.append(.component(.init(template: template, invocation: id, prefix: prefix, nodes: nodes,
                    inheritedMultiplier: inheritsMultiplier(component) ? multiplier : nil, portMapping: ports)))
            }
        }
    }
    private func inheritsMultiplier(_ component: ParsedComponent) -> Bool {
        guard let kind = component.type.rawValue.first,
              !"VEHAKNOPSTUWY".contains(kind) else { return false }
        return component.type != .behavioral || component.parameters["v"] == nil
    }
    private mutating func planMultiplicity(_ multiplier: MOSExpressionBinding) throws {
        try storage.reserve(&multipliedScopes, compiled.scopes.count)
        multipliedScopes.append(contentsOf: repeatElement(false, count: compiled.scopes.count))
        var reachable: [Bool] = []
        try storage.reserve(&reachable, compiled.scopes.count)
        reachable.append(contentsOf: repeatElement(false, count: compiled.scopes.count))
        var queue: [MOSScopeID] = []
        try storage.reserve(&queue, 1); queue.append(MOSScopeID(0)); reachable[0] = true
        var cursor = 0
        while cursor < queue.count {
            let scope = queue[cursor]; cursor += 1
            for template in compiled.scopes[Int(scope.rawValue)].components {
                try storage.spend()
                guard template.component.type == .subcircuitInstance,
                      let name = template.component.modelName, let target = try lookup(name, scope: scope) else { continue }
                if !reachable[Int(target.rawValue)] {
                    try storage.reserve(&queue, queue.count + 1); queue.append(target)
                    reachable[Int(target.rawValue)] = true
                }
                guard template.programs["m"] != nil, !multipliedScopes[Int(target.rawValue)] else { continue }
                var ownsMultiplier = false
                for binding in try compiled.snapshot.scope(target).parameterBindings {
                    try storage.spend()
                    if try compiled.snapshot.binding(binding).symbol == multiplier.symbol { ownsMultiplier = true }
                }
                if !ownsMultiplier { multipliedScopes[Int(target.rawValue)] = true }
            }
        }
        storage.budget.release(try MOSStorageBudget.capacityBytes(queue.capacity, of: MOSScopeID.self))
        storage.budget.release(try MOSStorageBudget.capacityBytes(reachable.capacity, of: Bool.self))
    }
    private func lookup(_ name: String, scope: MOSScopeID) throws -> MOSScopeID? {
        var current: MOSScopeID? = scope
        while let id = current {
            try storage.spend()
            let body = compiled.scopes[Int(id.rawValue)]
            if let target = body.subcircuits[name.lowercased()] { return target }
            current = body.parent
        }
        return nil
    }
}
