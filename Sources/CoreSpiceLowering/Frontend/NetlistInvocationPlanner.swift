import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

struct NetlistInvocationPlanner {
    let compiled: CompiledNetlist
    let limits: MOSResolutionLimits
    let control: (any MOSResolutionControlling)?
    let storage: FrontendStorage
    private var invocations: [MOSScopeInvocation] = []
    private var jobs: [FrontendExecutionJob] = []

    init(compiled: CompiledNetlist, limits: MOSResolutionLimits, control: (any MOSResolutionControlling)?) throws {
        self.compiled = compiled; self.limits = limits; self.control = control
        storage = FrontendStorage(limits: limits, control: control)
        try storage.budget.add(compiled.retainedBytes)
    }
    mutating func plan(overrides: [String: Double]) throws -> FrontendPlan {
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
        let invocation = try MOSScopeInvocation(id: id, scope: scope, callerInvocationID: caller,
            actuals: actuals, source: source, limits: limits)
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
                guard let name = component.modelName, let target = lookup(name, scope: scope),
                      let declaration = compiled.scopes[Int(target.rawValue)].subcircuit else {
                    throw LoweringError.undefinedSubcircuit(name: component.modelName ?? component.name, location: component.location)
                }
                guard nodes.count == declaration.ports.count else {
                    throw LoweringError.portCountMismatch(subcircuit: declaration.name,
                        expected: declaration.ports.count, got: nodes.count)
                }
                var actuals: [MOSInvocationActual] = []
                for binding in template.assignments {
                    try storage.reserve(&actuals, actuals.count + 1)
                    actuals.append(try .init(symbol: binding.symbol, program: binding.program,
                        source: frontendSource(component.origin, location: component.location), limits: limits))
                }
                guard actuals.count == component.parameters.count, component.parameterAssignments.allSatisfy({ $0.additionalValues.isEmpty }) else {
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
                jobs.append(.component(.init(template: template, invocation: id, prefix: prefix, nodes: nodes, portMapping: ports)))
            }
        }
    }
    private func lookup(_ name: String, scope: MOSScopeID) -> MOSScopeID? {
        var current: MOSScopeID? = scope
        while let id = current {
            let body = compiled.scopes[Int(id.rawValue)]
            if let target = body.subcircuits[name.lowercased()] { return target }
            current = body.parent
        }
        return nil
    }
}
