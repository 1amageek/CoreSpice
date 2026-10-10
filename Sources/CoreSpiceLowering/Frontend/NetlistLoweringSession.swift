import CoreSpiceIR
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Exclusive single-run scalar, random and resolved-circuit evaluation owner.
public struct NetlistLoweringSession: ~Copyable {
    public let compiled: CompiledNetlist
    public let graph: MOSInvocationGraph
    public let profile: MOSInputProfile
    public let limits: MOSResolutionLimits
    public let seed: UInt64
    public private(set) var circuit: CircuitIR?
    public var failureDiagnostic: MOSResolutionDiagnostic? { evaluator.failureDiagnostic }
    private var evaluator: MOSEvaluationSession
    private let storage: FrontendStorage
    private let jobs: [FrontendExecutionJob]
    private var scalarMemo: [Int: Double] = [:]
    private var modelMemo: [String: [String: ParameterValue]] = [:]

    init(compiled: CompiledNetlist, plan: FrontendPlan, profile: MOSInputProfile,
         limits: MOSResolutionLimits, seed: UInt64, evaluator: consuming MOSEvaluationSession) {
        self.compiled = compiled; graph = plan.graph; self.profile = profile
        self.limits = limits; self.seed = seed; storage = plan.storage; jobs = plan.jobs
        self.evaluator = evaluator
    }
    mutating func resolveRootBindings() throws { try resolveBindings(in: 0) }
    public mutating func poison(_ cause: MOSResolutionFailure) { evaluator.poison(cause) }
    public mutating func evaluateScalar(_ slot: NetlistScalarSlot) throws -> Double {
        do {
            try evaluator.checkHealthy()
            guard compiled.identity.sameStorage(as: slot.identity) else { throw MOSResolutionFailure.conditionMismatch }
            if let cached = scalarMemo[slot.index] { return cached }
            let value = try evaluateMOSProgram(slot.program, invocation: 0, lexicalScope: MOSScopeID(0),
                from: compiled.snapshot, session: &evaluator)
            try storage.reserve(&scalarMemo, scalarMemo.count + 1); scalarMemo[slot.index] = value
            return value
        } catch { throw poisonAndReturn(error) }
    }
    public mutating func lower(geometryScale: Double? = nil, expandModels: Bool = true) throws {
        do {
            try evaluator.checkHealthy()
            guard circuit == nil else { throw MOSResolutionFailure.conditionMismatch }
            var scale = geometryScale ?? 1
            if geometryScale == nil {
                for (index, control) in compiled.source.controls.enumerated() {
                    if case .option(let name, _, _) = control, name.lowercased() == "scale" {
                        scale = try evaluateScalar(compiled.scalarSlot(at: .control(index: index, field: "value")))
                    }
                }
            }
            guard scale.isFinite, scale > 0 else { throw MOSResolutionFailure.invalidRequest }
            var builder = try BoundedFrontendNetlist(storage: storage)
            // K emission is deferred, while its scalar slot evaluation retains source order.
            var deferred: [(FrontendComponentJob, [String: ParameterValue], String, ResolvedDeviceModel?, ModelConsumption)] = []
            for job in jobs {
                try storage.spend()
                switch job {
                case .enter(let invocation): if invocation != 0 { try resolveBindings(in: invocation) }
                case .component(let component):
                    if component.template.component.type == .mosfet {
                        try emitMOS(component, scale: scale, into: &builder)
                    } else {
                        let resolved = try resolveNonMOS(component, scale: scale, expandModels: expandModels, into: &builder)
                        if component.template.component.type == .coupledInductors {
                            try storage.reserve(&deferred, deferred.count + 1)
                            deferred.append((component, resolved.parameters, resolved.typeName, resolved.model, resolved.consumption))
                        } else {
                            try NonMOSComponentEmitter().emit(component.template.component, name: fullName(component),
                                typeName: resolved.typeName, nodes: component.nodes, parameters: resolved.parameters,
                                model: resolved.model, consumption: resolved.consumption, prefix: component.prefix,
                                referencedNodes: resolved.readNodes, referencedBranches: resolved.readBranches, into: &builder)
                        }
                    }
                }
            }
            for (job, parameters, type, model, consumption) in deferred {
                try NonMOSComponentEmitter().emit(job.template.component, name: fullName(job), typeName: type,
                    nodes: job.nodes, parameters: parameters, model: model, consumption: consumption,
                    prefix: job.prefix, referencedNodes: [], referencedBranches: [], into: &builder)
            }
            circuit = try builder.build()
        } catch { throw poisonAndReturn(error) }
    }
    public consuming func finish() throws -> LoweredCircuit {
        try evaluator.checkHealthy()
        guard let circuit else { throw MOSResolutionFailure.invalidRequest }
        let steps = evaluator.evaluationSteps
        let retained = try checkedAdd(storage.budget.bytes, evaluator.retainedBytes)
        let peak = try checkedAdd(storage.budget.peakBytes, evaluator.peakOwnedBufferBytes)
        let compiled = self.compiled, graph = self.graph, profile = self.profile
        let provenance = NetlistEvaluationProvenance(profile: profile,
            evaluation: evaluator.finishProvenance(), evaluationSteps: steps,
            retainedBytes: retained, peakOwnedBufferBytes: peak)
        return LoweredCircuit(circuit: circuit, compiled: compiled, graph: graph, evaluationProvenance: provenance)
    }
    private func checkedAdd(_ first: UInt64, _ second: UInt64) throws -> UInt64 {
        let (value, overflow) = first.addingReportingOverflow(second)
        guard !overflow else { throw MOSResolutionFailure.arithmeticOverflow }; return value
    }
    private mutating func poisonAndReturn(_ error: any Error) -> any Error {
        if let failure = error as? MOSResolutionFailure { evaluator.poison(failure) }
        else { evaluator.poison(.invalidRequest) }
        return error
    }
    private mutating func resolveBindings(in invocation: UInt64) throws {
        for binding in graph.finalBindings where binding.ownerInvocation == invocation {
            _ = try evaluateMOSBinding(binding.symbol, invocation: invocation,
                from: compiled.snapshot, session: &evaluator)
        }
    }
    private func fullName(_ job: FrontendComponentJob) -> String {
        job.prefix.isEmpty ? job.template.component.name : job.prefix + "." + job.template.component.name
    }
    private mutating func emitMOS(_ job: FrontendComponentJob, scale: Double, into builder: inout BoundedFrontendNetlist) throws {
        let component = job.template.component
        guard component.nodes.count == 4, let model = component.modelName,
              let reference = compiled.snapshot.symbol(named: model.lowercased()) else {
            throw LoweringError.invalidComponent(name: fullName(job), reason: "MOS requires four ports, a .model reference and scalar supplied assignments")
        }
        if let reason = job.template.mosAssignmentFailure {
            throw LoweringError.invalidComponent(name: fullName(job), reason: reason)
        }
        let request = try MOSResolutionRequest(source: frontendSource(component.origin, location: component.location),
            instance: fullName(job), scope: job.template.scope, scopeInstantiation: job.invocation,
            modelReference: reference, profile: profile, bindings: job.template.assignments,
            geometryScale: scale, seed: seed, limits: limits)
        let resolved = try resolveMOS(request, from: compiled.snapshot,
            schemas: StandardMOSModelSchemas(), session: &evaluator)
        if job.template.hasMOSInitialConditionVector {
            do {
                let schema = try StandardMOSModelSchemas().schema(for: resolved.release)
                guard try schema.parameter(named: "ic", role: .instance).kind == .vector else {
                    throw MOSResolutionFailure.schema(.invalidValue(name: "ic"))
                }
            } catch let failure as MOSSchemaFailure { throw MOSResolutionFailure.schema(failure) }
        }
        try storage.budget.add(resolved.retainedBytes)
        let type = (resolved.polarity == .nmos ? "nmos_l" : "pmos_l") + String(resolved.release.level)
        try builder.addInstance(name: fullName(job), typeName: type, nodes: job.nodes, mos: .resolved(resolved))
    }
    private mutating func resolveNonMOS(_ job: FrontendComponentJob, scale: Double, expandModels: Bool,
        into builder: inout BoundedFrontendNetlist) throws -> FrontendResolvedComponent {
        let component = job.template.component, name = fullName(job)
        let emitter = NonMOSComponentEmitter()
        if component.type == .capacitor, component.parameters["q"] != nil {
            // FIXME(INCOMPLETE_IMPLEMENTATION): Native charge-capacitor physics is absent.
            // Selected frontend components reach this before numerical slot evaluation.
            // Admit only after dQ/dt, Jacobian, AC and accepted-history proofs exist.
            throw LoweringError.invalidComponent(name: name, reason: "Charge-based capacitor execution is not implemented")
        }
        if let reason = emitter.unsupportedComponentParameterReason(component) {
            throw LoweringError.invalidComponent(name: name, reason: reason)
        }
        var selected = component.modelName.flatMap { compiled.model(named: $0, scope: job.template.scope) }
        var passiveUsesModel = false
        if component.modelName == nil, let candidate = component.passiveModelCandidate {
            let hasParameter: Bool
            if let symbol = compiled.snapshot.symbol(named: candidate.lowercased()) {
                hasParameter = try graph.numericBinding(symbol, in: job.invocation) != nil
            } else { hasParameter = false }
            if !(component.type == .capacitor && (hasParameter || candidate.lowercased() == "c")) {
                selected = compiled.model(named: candidate, scope: job.template.scope)
                passiveUsesModel = selected != nil
            }
        }
        if component.type.requiresModelForNativeExecution, selected == nil {
            throw LoweringError.undefinedModel(name: component.modelName ?? component.name, location: component.location)
        }
        if component.modelName != nil, selected == nil {
            throw LoweringError.undefinedModel(name: component.modelName!, location: component.location)
        }
        if let selected {
            guard component.type.accepts(model: selected.model) else {
                throw LoweringError.invalidComponent(name: name, reason: "Referenced model type does not match component")
            }
            if let reason = emitter.unsupportedModelReason(selected.model) {
                throw LoweringError.invalidComponent(name: name, reason: reason)
            }
            if component.type == .resistor, selected.model.level != nil {
                throw LoweringError.invalidComponent(name: name, reason: "Resistor model level is unsupported")
            }
        }
        let type = try componentType(component, model: selected?.model)
        var parameters: [String: ParameterValue] = [:]
        var model: ResolvedDeviceModel?
        var consumption: ModelConsumption = .modelFree
        if let selected {
            let values = try evaluateModel(selected, from: job.invocation)
            let resolved = ResolvedDeviceModel(name: selected.model.name, typeName: type,
                parameters: values, declarationID: selected.model.origin?.declarationID)
            try storage.text(resolved.name); try storage.text(resolved.typeName); try storage.text(resolved.declarationID)
            consumption = .selected(resolved)
            if component.type == .resistor { model = resolved }
            else if expandModels || component.type == .uniformRC {
                try storage.reserve(&parameters, values.count)
                for (key, value) in values { parameters[key] = value }
            }
        }
        var readNodes: [String] = [], readBranches: [String] = []
        for (key, value) in try storage.entries(component.parameters) {
            try storage.spend()
            if passiveUsesModel && key == (component.type == .resistor ? "r" : "c") { continue }
            try storage.reserve(&parameters, parameters.count + 1)
            if key == "control_source" {
                parameters[key] = try emitter.lowerControlSourceParameter(value, fullName: name, prefix: job.prefix)
            } else if key == "pwl", case .numericVector(let vector) = value,
                component.type == .voltageSource || component.type == .currentSource {
                parameters[key] = .realVector(vector)
            } else if case .expression(let expression) = value,
                try (component.type == .behavioral || (component.type == .resistor && (key == "r" || key == "resistance") && hasRuntime(expression, scope: job.template.scope))) {
                let values = try runtimeParameters(invocation: job.invocation)
                guard let program = job.template.programs[key.lowercased()] else { throw MOSResolutionFailure.invalidRequest }
                evaluator.recordExpression(binding: nil, program: program, invocation: job.invocation, scope: job.template.scope)
                try evaluator.recordRootVisit(.program(program, invocation: job.invocation, lexicalScope: job.template.scope))
                let result = try BehavioralExpressionLowerer(parameters: values, compiled: compiled,
                    lexicalScope: job.template.scope, prefix: job.prefix, portMapping: job.portMapping)
                    .lower(expression, into: &builder, session: &evaluator)
                parameters[key] = .behavioralExpression(result.expression)
                try storage.reserve(&readNodes, readNodes.count + result.referencedNodeNames.count)
                readNodes.append(contentsOf: result.referencedNodeNames)
                try storage.reserve(&readBranches, readBranches.count + result.referencedBranchNames.count)
                readBranches.append(contentsOf: result.referencedBranchNames)
            } else {
                guard let program = job.template.programs[key.lowercased()] else {
                    throw LoweringError.invalidComponent(name: name, reason: "Parameter '\(key)' must be scalar")
                }
                parameters[key] = .real(try evaluateMOSProgram(program, invocation: job.invocation,
                    lexicalScope: job.template.scope, from: compiled.snapshot, session: &evaluator))
            }
        }
        if component.type == .resistor {
            for dimension in ["l", "w"] {
                if case .real(let value) = parameters[dimension] {
                    let normalized = value * scale
                    guard normalized.isFinite, normalized > 0 else {
                        throw LoweringError.invalidComponent(name: name, reason: "Scaled resistor geometry must be finite and positive")
                    }
                    parameters[dimension] = .real(normalized)
                }
            }
        }
        return .init(typeName: type, parameters: parameters, model: model, consumption: consumption,
            readNodes: readNodes, readBranches: readBranches)
    }
    private mutating func evaluateModel(_ template: FrontendModelTemplate, from invocation: UInt64) throws -> [String: ParameterValue] {
        let owner = try graph.lexicalOwner(of: template.scope, from: invocation)
        let key = String(owner) + ":" + String(template.scope.rawValue) + ":" + template.model.name.lowercased()
        if let cached = modelMemo[key] { return cached }
        var values: [String: ParameterValue] = [:]
        for (name, program) in template.programs {
            let number = try evaluateMOSProgram(program, invocation: owner, lexicalScope: template.scope,
                from: compiled.snapshot, session: &evaluator)
            try storage.reserve(&values, values.count + 1); values[name] = .real(number)
        }
        for (name, value) in template.model.parameters where name != "version" && name != "level" {
            switch value {
            case .numeric, .expression, .boolean: break
            case .string, .numericVector:
                throw LoweringError.invalidComponent(name: template.model.name, reason: "Model coefficient '\(name)' must be scalar")
            }
        }
        try storage.text(key); try storage.reserve(&modelMemo, modelMemo.count + 1); modelMemo[key] = values
        return values
    }
    private mutating func runtimeParameters(invocation: UInt64) throws -> [String: Double] {
        var values: [String: Double] = [:]
        var current: UInt64? = invocation
        while let id = current {
            for binding in graph.finalBindings where binding.ownerInvocation == id {
                let name = try compiled.snapshot.name(of: binding.symbol)
                if values[name] == nil {
                    let number = try evaluateMOSBinding(binding.symbol, invocation: id, from: compiled.snapshot, session: &evaluator)
                    try storage.reserve(&values, values.count + 1); values[name] = number
                }
            }
            current = try graph.invocation(id).callerInvocationID
        }
        return values
    }
    private func hasRuntime(_ expression: ParsedExpression, scope: MOSScopeID,
        visited: Set<String> = [], bound: Set<String> = [], depth: Int = 1) throws -> Bool {
        guard depth <= limits.maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        try storage.spend()
        switch expression {
        case .literal: return false
        case .identifier(let name): return ["time", "temper", "hertz"].contains(name.lowercased()) && !bound.contains(name.lowercased())
        case .unaryOperation(_, let value): return try hasRuntime(value, scope: scope, visited: visited, bound: bound, depth: depth + 1)
        case .binaryOperation(_, let left, let right): return try hasRuntime(left, scope: scope, visited: visited, bound: bound, depth: depth + 1) || hasRuntime(right, scope: scope, visited: visited, bound: bound, depth: depth + 1)
        case .conditional(let condition, let yes, let no): return try hasRuntime(condition, scope: scope, visited: visited, bound: bound, depth: depth + 1) || hasRuntime(yes, scope: scope, visited: visited, bound: bound, depth: depth + 1) || hasRuntime(no, scope: scope, visited: visited, bound: bound, depth: depth + 1)
        case .functionCall(let name, let arguments):
            if name.lowercased() == "v" || name.lowercased() == "i" { return true }
            for argument in arguments { if try hasRuntime(argument, scope: scope, visited: visited, bound: bound, depth: depth + 1) { return true } }
            guard let (function, lexical) = compiled.function(named: name, scope: scope) else { return false }
            let key = String(lexical.rawValue) + ":" + name.lowercased()
            if visited.contains(key) { return true }
            guard visited.count < limits.maximumFunctionDepth else { throw MOSResolutionFailure.limitExceeded(.functionDepth) }
            var next = visited, formals: Set<String> = []
            try storage.budget.add(MOSStorageBudget.capacityBytes(visited.capacity, of: String.self))
            try storage.budget.reserveSet(&next, required: visited.count + 1); next.insert(key); try storage.text(key)
            for formal in function.parameters {
                try storage.budget.reserveSet(&formals, required: formals.count + 1); try storage.text(formal.lowercased()); formals.insert(formal.lowercased())
            }
            return try hasRuntime(function.body, scope: lexical, visited: next, bound: formals, depth: depth + 1)
        }
    }
    private func componentType(_ component: ParsedComponent, model: ParsedModel?) throws -> String {
        let controlled = component.parameters["control_source"] != nil
        switch component.type {
        case .resistor: return "resistor"
        case .capacitor: return "capacitor"
        case .inductor: return "inductor"
        case .voltageSource: return "vsource"
        case .currentSource: return "isource"
        case .vcvs: return "vcvs"
        case .vccs: return "vccs"
        case .cccs: return controlled ? "cccs_ref" : "cccs"
        case .ccvs: return controlled ? "ccvs_ref" : "ccvs"
        case .diode: return "diode"
        case .bjt: return model?.type == .npn ? "npn" : "pnp"
        case .jfet: return model?.type == .njf ? "njfet" : "pjfet"
        case .mesfet: return model?.type == .nmf ? "nmesfet" : "pmesfet"
        case .transmissionLine: return "tline"
        case .uniformRC: return "urc"
        case .coupledInductors: return "mutual"
        case .behavioral: return component.parameters["v"] != nil ? "behavioral_vsource" : "behavioral_isource"
        case .switch_: return "vswitch"
        case .currentSwitch: return controlled ? "cswitch_ref" : "cswitch"
        case .mosfet, .subcircuitInstance: throw MOSResolutionFailure.invalidRequest
        }
    }
}
