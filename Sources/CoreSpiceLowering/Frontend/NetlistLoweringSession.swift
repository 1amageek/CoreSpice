import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts
import CoreSpiceIR
import CoreSpiceOSDIContracts
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR

/// Exclusive single-run scalar, random and resolved-circuit evaluation owner.
public struct NetlistLoweringSession: ~Copyable {
    public let environment: EvaluationEnvironment
    public let temperatureProvenance: NetlistTemperatureProvenance
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
    private var diodeMemo: [DiodeModelMemoKey: DiodeModelMemoEntry] = [:]
    private var modelMemo: [String: [String: ParameterValue]] = [:]
    private var sourceScalars: [NetlistSourceScalarOverride] = []
    private var externalPreparations: [CheckedExternalMOSPreparation] = []

    init(compiled: CompiledNetlist, plan: FrontendPlan, profile: MOSInputProfile,
         limits: MOSResolutionLimits, seed: UInt64, evaluator: consuming MOSEvaluationSession,
         temperatureProvenance: NetlistTemperatureProvenance) throws {
        guard let environment = evaluator.environment else { throw MOSResolutionFailure.environmentUnavailable }
        // Diode diagnostic coordinates have a separate bounded owner from the evaluator arena.
        try plan.storage.budget.add(limits.maximumDiagnosticBytes)
        var memo: [Int: Double] = [:]
        for (origin, value) in [(temperatureProvenance.ambient, try environment.ambient.celsius().value),
                                (temperatureProvenance.nominal, try environment.nominal.celsius().value)] {
            if case .sourceControl(let index) = origin {
                let slot = try compiled.scalarSlot(at: .control(index: index, field: "value"))
                try plan.storage.reserve(&memo, memo.count + 1); memo[slot.index] = value
            }
        }
        self.environment = environment; self.temperatureProvenance = temperatureProvenance
        self.compiled = compiled; graph = plan.graph; self.profile = profile
        self.limits = limits; self.seed = seed; storage = plan.storage; jobs = plan.jobs
        scalarMemo = memo; self.evaluator = evaluator
    }
    mutating func resolveRootBindings() throws { try resolveBindings(in: 0) }
    public mutating func poison(_ cause: MOSResolutionFailure) { evaluator.poison(cause) }
    public mutating func evaluateScalar(_ slot: NetlistScalarSlot) throws -> Double {
        do {
            try evaluator.checkHealthy()
            guard compiled.identity.sameStorage(as: slot.identity) else { throw MOSResolutionFailure.conditionMismatch }
            if let cached = scalarMemo[slot.index] { return cached }
            if case .control(let index, _) = slot.address {
                switch compiled.source.controls[index] {
                case .temp: throw MOSResolutionFailure.invalidRequest
                case .option(let name, _, _) where name.lowercased() == "temp" || name.lowercased() == "tnom":
                    throw MOSResolutionFailure.invalidRequest
                default: break
                }
            }
            let value = try evaluateMOSProgram(slot.program, invocation: 0, lexicalScope: MOSScopeID(0),
                from: compiled.snapshot, session: &evaluator)
            try storage.reserve(&scalarMemo, scalarMemo.count + 1); scalarMemo[slot.index] = value
            return value
        } catch { throw poisonAndReturn(error) }
    }
    /// Checks one source width flag through the shared scalar memo.
    public mutating func evaluateMOSWidthPerFingerOption(at index: Int) throws -> Bool {
        do {
            try evaluator.checkHealthy()
            guard compiled.source.controls.indices.contains(index),
                  case .option(let name, let supplied, _) = compiled.source.controls[index],
                  name.lowercased() == "wnflag" else { throw MOSResolutionFailure.conditionMismatch }
            guard profile == .pinnedNgspiceNormalV1 else {
                throw LoweringError.unsupportedFeature(feature: "wnflag requires pinnedNgspiceNormalV1")
            }
            guard let supplied else { throw MOSResolutionFailure.schema(.invalidValue(name: "wnflag")) }
            switch supplied {
            case .numeric, .expression, .boolean: break
            case .string, .numericVector: throw MOSResolutionFailure.schema(.invalidValue(name: "wnflag"))
            }
            let value = try evaluateScalar(compiled.scalarSlot(at: .control(index: index, field: "value")))
            guard value == 0 || value == 1 else { throw MOSResolutionFailure.schema(.invalidValue(name: "wnflag")) }
            return value == 1
        } catch { throw poisonAndReturn(error) }
    }
    public mutating func lower(geometryScale: Double? = nil, globalWidthPerFinger: Bool? = nil,
                               expandModels: Bool = true, diodeProfile: DiodeInputProfile? = nil,
                               osdiInstances: [String: OSDIResolvedInstance] = [:],
                               externalMOSPreparers: [String: any ExternalMOSPreparing] = [:]) throws {
        do {
            try evaluator.checkHealthy()
            guard circuit == nil else { throw MOSResolutionFailure.conditionMismatch }
            guard globalWidthPerFinger != true || profile == .pinnedNgspiceNormalV1 else {
                throw LoweringError.unsupportedFeature(feature: "Per-finger selection requires pinnedNgspiceNormalV1")
            }
            var scale = geometryScale ?? 1
            var sourceWidthPerFinger = false
            for (index, control) in compiled.source.controls.enumerated() {
                try storage.spend()
                guard case .option(let name, _, _) = control else { continue }
                switch name.lowercased() {
                case "scale" where geometryScale == nil:
                    scale = try evaluateScalar(compiled.scalarSlot(at: .control(index: index, field: "value")))
                case "wnflag": sourceWidthPerFinger = try evaluateMOSWidthPerFingerOption(at: index)
                default: break
                }
            }
            let widthPerFinger = globalWidthPerFinger ?? sourceWidthPerFinger
            guard scale.isFinite, scale > 0 else { throw MOSResolutionFailure.invalidRequest }
            var builder = try BoundedFrontendNetlist(storage: storage)
            // K emission is deferred, while its scalar slot evaluation retains source order.
            var deferred: [(FrontendComponentJob, [String: ParameterValue], String, ResolvedDeviceModel?, ModelConsumption)] = []
            for key in externalMOSPreparers.keys {
                try storage.spend()
                guard !key.isEmpty, key == key.lowercased() else {
                    throw ExternalMOSPreparationFailure.invalidSelection(key)
                }
            }
            var osdiCount = 0
            var externalCount = 0
            for job in jobs {
                try storage.spend()
                switch job {
                case .enter(let invocation): if invocation != 0 { try resolveBindings(in: invocation) }
                case .component(let component):
                    if component.template.component.type == .osdi {
                        try emitOSDI(component, instances: osdiInstances, into: &builder)
                        osdiCount += 1
                    } else if component.template.component.type == .mosfet {
                        if let preparer = externalMOSPreparers[fullName(component).lowercased()] {
                            try emitExternalMOS(component, scale: scale, widthPerFinger: widthPerFinger,
                                                preparer: preparer, into: &builder)
                            externalCount += 1
                        } else {
                            try emitMOS(component, scale: scale, widthPerFinger: widthPerFinger, into: &builder)
                        }
                    } else if component.template.component.type == .diode {
                        var resolver = DiodeResolver(compiled: compiled, job: component, storage: storage, limits: limits, graph: graph)
                        let resolved = try resolver.resolve(schemas: StandardDiodeModelSchemas(), profile: diodeProfile, scale: scale, seed: seed,
                                                            session: &evaluator, memo: &diodeMemo, sourceScalars: &sourceScalars)
                        try builder.addInstance(name: fullName(component), typeName: "diode", nodes: component.nodes,
                                                diode: .resolved(resolved), modelConsumption: .unrecorded)
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
            guard osdiCount == osdiInstances.count else {
                throw LoweringError.invalidOSDIInput(name: "catalog", reason: "Unused OSDI instance catalog entry", location: nil)
            }
            guard externalCount == externalMOSPreparers.count else {
                for key in externalMOSPreparers.keys {
                    try storage.spend()
                    if !externalPreparations.contains(where: { $0.preparation.source.resolution.instance.lowercased() == key }) {
                        throw ExternalMOSPreparationFailure.unusedSelection(key)
                    }
                }
                throw ExternalMOSPreparationFailure.sourceMismatch
            }
            circuit = try builder.build(environment: environment.identity)
        } catch { throw poisonAndReturn(error) }
    }
    public consuming func finish() throws -> LoweredCircuit {
        try evaluator.checkHealthy()
        guard let circuit else { throw MOSResolutionFailure.invalidRequest }
        let steps = evaluator.evaluationSteps
        let retained = try checkedAdd(storage.budget.bytes, evaluator.retainedBytes)
        let peak = try checkedAdd(storage.budget.peakBytes, evaluator.peakOwnedBufferBytes)
        let compiled = self.compiled, graph = self.graph, profile = self.profile
        let provenance = NetlistEvaluationProvenance(temperatures: temperatureProvenance, sourceScalars: sourceScalars, profile: profile,
            evaluation: evaluator.finishProvenance(), evaluationSteps: steps,
            retainedBytes: retained, peakOwnedBufferBytes: peak)
        return LoweredCircuit(circuit: circuit, compiled: compiled, graph: graph, evaluationProvenance: provenance,
                              externalMOSPreparations: externalPreparations)
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
    private func mosRequest(_ job: FrontendComponentJob, scale: Double, widthPerFinger: Bool) throws
        -> (request: MOSResolutionRequest, overrides: [FrontendScalarOverride]) {
        let component = job.template.component
        guard component.nodes.count == 4, let model = component.modelName,
              let reference = compiled.snapshot.symbol(named: model.lowercased()) else {
            throw LoweringError.invalidComponent(name: fullName(job), reason: "MOS requires four ports, a .model reference and scalar supplied assignments")
        }
        if let reason = job.template.mosAssignmentFailure {
            throw LoweringError.invalidComponent(name: fullName(job), reason: reason)
        }
        var bindings = job.template.assignments
        let overrides = compiled.scalarOverrides[fullName(job).lowercased()] ?? []
        if !overrides.isEmpty {
            try storage.retain(bindings)
            for override in overrides where override.source.role == .instance {
                for index in bindings.indices {
                    try storage.spend()
                    if bindings[index].symbol == override.binding.symbol { bindings[index] = override.binding }
                }
            }
        }
        var modelOverrides: [MOSExpressionBinding] = []
        for override in overrides where override.source.role == .model {
            try storage.reserve(&modelOverrides, modelOverrides.count + 1)
            modelOverrides.append(override.binding)
        }
        if let inherited = job.inheritedMultiplier {
            try storage.retain(bindings)
            bindings.removeAll { $0.symbol == inherited.symbol }
            try storage.reserve(&bindings, bindings.count + 1); bindings.append(inherited)
        }
        let request = try MOSResolutionRequest(source: frontendSource(component.origin, location: component.location),
            instance: fullName(job), scope: job.template.scope, scopeInstantiation: job.invocation,
            modelReference: reference, profile: profile, bindings: bindings, modelOverrides: modelOverrides,
            geometryScale: scale, seed: seed, globalWidthPerFinger: widthPerFinger, limits: limits)
        return (request, overrides)
    }
    private mutating func emitMOS(_ job: FrontendComponentJob, scale: Double, widthPerFinger: Bool, into builder: inout BoundedFrontendNetlist) throws {
        let (request, overrides) = try mosRequest(job, scale: scale, widthPerFinger: widthPerFinger)
        let resolved = try resolveMOS(request, from: compiled.snapshot,
            schemas: StandardMOSModelSchemas(), session: &evaluator)
        let schema = try StandardMOSModelSchemas().schema(for: resolved.release)
        for (index, override) in overrides.enumerated() where override.source.role == .instance {
            guard job.inheritedMultiplier?.symbol != override.binding.symbol else {
                throw LoweringError.invalidComponent(name: fullName(job), reason: "Inherited multiplicity is not an independent source scalar")
            }
            let definition = try schema.parameter(named: override.name, role: .instance)
            guard definition.supportsScalarPerturbation else {
                throw MOSResolutionFailure.schema(.invalidValue(name: override.name))
            }
            for prior in overrides[..<index] where prior.source.role == .instance {
                try storage.spend()
                let earlier = try schema.parameter(named: prior.name, role: .instance)
                guard earlier.canonicalName != definition.canonicalName else {
                    throw MOSResolutionFailure.duplicateParameter(override.binding.symbol)
                }
            }
        }
        if compiled.captureSourceScalars {
            guard let raw = resolved.rawInstanceParameters else { throw MOSResolutionFailure.invalidResolvedInstance }
            for parameter in resolved.instanceParameters {
                let name = try compiled.snapshot.name(of: parameter.symbol)
                let definition = try schema.parameter(named: name, role: .instance)
                guard definition.supportsScalarPerturbation,
                      job.template.programs[name] != nil,
                      job.inheritedMultiplier?.symbol != parameter.symbol else { continue }
                guard let source = raw.first(where: { $0.symbol == parameter.symbol }) else {
                    throw MOSResolutionFailure.invalidResolvedInstance
                }
                try recordSourceScalar(instance: fullName(job), name: name, role: .instance, value: source.value)
            }
            for parameter in resolved.modelCoefficients {
                let name = try compiled.snapshot.name(of: parameter.symbol)
                let definition = try schema.parameter(named: name, role: .model)
                if definition.supportsScalarPerturbation {
                    try recordSourceScalar(instance: fullName(job), name: name, role: .model, value: parameter.value)
                }
            }
        }
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
    private mutating func emitExternalMOS(_ job: FrontendComponentJob, scale: Double,
        widthPerFinger: Bool, preparer: any ExternalMOSPreparing, into builder: inout BoundedFrontendNetlist) throws {
        let storage = self.storage
        let (request, _) = try mosRequest(job, scale: scale, widthPerFinger: widthPerFinger)
        let candidates = try mosOwningCandidates(request, snapshot: compiled.snapshot, session: &evaluator)
        guard candidates.ids.count <= limits.maximumCandidates else { throw MOSResolutionFailure.limitExceeded(.candidates) }
        let owner = try graph.lexicalOwner(of: candidates.scope, from: request.scopeInstantiation)
        var ids: [MOSDeclarationID] = []
        try storage.reserve(&ids, candidates.ids.count)
        for id in candidates.ids { try storage.spend(); ids.append(id) }
        try storage.budget.add(ExternalMOSSourceRequest.retainedInlineBytes)
        let source = ExternalMOSSourceRequest(original: job.template.component, resolution: request,
            compiled: compiled, graph: graph, candidateDeclarations: ids, candidateScope: candidates.scope,
            candidateInvocation: owner, isFamily: candidates.family, terminals: job.nodes, environment: environment)
        var trace: [ExternalMOSEvaluatedScalar] = []
        var callbackFailure: (any Error)?
        let identity = preparer.identity
        let result = try preparer.prepare(source, evaluate: { address in
            do {
                if let callbackFailure { throw callbackFailure }
                try storage.spend()
                for fact in trace {
                    try storage.spend()
                    if fact.address == address { return fact.value }
                }
                let binding: MOSExpressionBinding
                let invocation: UInt64
                let scope: MOSScopeID
                switch address {
                case .instance(let index):
                    guard request.bindings.indices.contains(index) else { throw ExternalMOSPreparationFailure.invalidScalarAddress }
                    binding = request.bindings[index]; invocation = request.scopeInstantiation; scope = request.scope
                case .modelOverride(let index):
                    guard request.modelOverrides.indices.contains(index) else { throw ExternalMOSPreparationFailure.invalidScalarAddress }
                    binding = request.modelOverrides[index]; invocation = request.scopeInstantiation; scope = request.scope
                case .model(let id, let index):
                    var admitted = false
                    for candidate in ids {
                        try storage.spend()
                        if candidate == id { admitted = true; break }
                    }
                    guard admitted else { throw ExternalMOSPreparationFailure.invalidCandidate }
                    let model = try source.snapshot.declaration(id)
                    guard model.coefficients.indices.contains(index) else { throw ExternalMOSPreparationFailure.invalidScalarAddress }
                    binding = model.coefficients[index]; invocation = owner; scope = model.scope
                }
                let value = try evaluateMOSProgram(binding.program, invocation: invocation, lexicalScope: scope,
                                                  from: source.snapshot, session: &evaluator)
                try storage.reserve(&trace, trace.count + 1)
                trace.append(ExternalMOSEvaluatedScalar(address: address, value: value))
                return value
            } catch { callbackFailure = error; throw error }
        }, chargeWork: {
            do {
                if let callbackFailure { throw callbackFailure }
                try storage.spend()
            } catch { callbackFailure = error; throw error }
        })
        if let callbackFailure { throw callbackFailure }
        guard result.source === source, ids.contains(result.selectedDeclaration),
              !identity.isEmpty, preparer.identity == identity, result.facts.profileIdentity == identity else {
            throw ExternalMOSPreparationFailure.sourceMismatch
        }
        let declaration = try source.snapshot.declaration(result.selectedDeclaration)
        guard result.resolved.binding.modelName.lowercased() == declaration.originalName.lowercased() else {
            throw ExternalMOSPreparationFailure.sourceMismatch
        }
        try validateExternalFacts(result.facts, resolved: result.resolved, trace: trace)
        try retainOSDI(result.resolved)
        try storage.text(result.facts.profileIdentity)
        try storage.retain(result.facts.parameters)
        for fact in result.facts.parameters {
            try storage.spend(); try storage.text(fact.name)
            if case .string(let text) = fact.providerValue { try storage.text(text) }
        }
        try storage.reserve(&externalPreparations, externalPreparations.count + 1)
        externalPreparations.append(CheckedExternalMOSPreparation(preparation: result, evaluatedScalars: trace))
        try builder.addInstance(name: fullName(job), typeName: "osdi", nodes: job.nodes,
                                osdi: .resolved(result.resolved), modelConsumption: .unrecorded)
    }

    private func validateExternalFacts(_ facts: ExternalMOSPreparationFacts, resolved: OSDIResolvedInstance,
                                      trace: [ExternalMOSEvaluatedScalar]) throws {
        let geometry = facts.geometry
        for value in [geometry.effectiveLengthSI, geometry.totalWidthSI, geometry.selectionLengthSI,
                      geometry.selectionWidthSI, geometry.fingerCount, geometry.parallelMultiplier] {
            try storage.spend()
            guard value.isFinite, value > 0 else { throw ExternalMOSPreparationFailure.invalidFacts }
        }
        for value in [geometry.rawLength, geometry.rawWidth] {
            guard value?.isFinite != false else { throw ExternalMOSPreparationFailure.invalidFacts }
        }
        for fact in facts.parameters {
            try storage.spend()
            guard !fact.name.isEmpty, fact.rawValue?.isFinite != false, fact.normalizedValue?.isFinite != false else {
                throw ExternalMOSPreparationFailure.invalidFacts
            }
            if let address = fact.address {
                var matched = false
                for evaluated in trace {
                    try storage.spend()
                    if evaluated.address == address, fact.rawValue?.bitPattern == evaluated.value.bitPattern { matched = true }
                }
                guard matched else { throw ExternalMOSPreparationFailure.parameterFactMismatch(fact.name) }
            }
            if let value = fact.providerValue {
                let assignments = fact.role == .model ? resolved.binding.modelParameters : resolved.instanceParameters
                var matched = false
                for assignment in assignments {
                    try storage.spend()
                    if assignment.name == fact.name, assignment.scope == fact.role, assignment.value == value { matched = true }
                }
                guard fact.isGiven, matched else { throw ExternalMOSPreparationFailure.parameterFactMismatch(fact.name) }
            }
        }
        for assignments in [resolved.binding.modelParameters, resolved.instanceParameters] {
            for assignment in assignments {
                var matches = 0
                for fact in facts.parameters {
                    try storage.spend()
                    if fact.name == assignment.name, fact.role == assignment.scope, fact.providerValue == assignment.value { matches += 1 }
                }
                guard matches == 1 else { throw ExternalMOSPreparationFailure.parameterFactMismatch(assignment.name) }
            }
        }
    }

    private func emitOSDI(_ job: FrontendComponentJob, instances: [String: OSDIResolvedInstance],
                          into builder: inout BoundedFrontendNetlist) throws {
        let component = job.template.component, name = fullName(job)
        guard job.inheritedMultiplier == nil else {
            throw LoweringError.invalidOSDIInput(name: name, reason: "OSDI hierarchical multiplicity is unsupported", location: component.location)
        }
        guard let symbol = component.modelName,
              let selected = compiled.model(named: symbol, scope: job.template.scope) else {
            throw LoweringError.undefinedModel(name: component.modelName ?? name, location: component.location)
        }
        guard selected.model.type == .osdi else {
            throw LoweringError.invalidOSDIInput(name: name, reason: "N requires an explicit OSDI model declaration", location: component.location)
        }
        guard let resolved = instances[name],
              resolved.binding.modelName.lowercased() == selected.model.name.lowercased() else {
            throw LoweringError.invalidOSDIInput(name: name, reason: "Missing or mismatched exact OSDI instance catalog binding", location: component.location)
        }
        try retainOSDI(resolved)
        try builder.addInstance(name: name, typeName: "osdi", nodes: job.nodes,
                                osdi: .resolved(resolved), modelConsumption: .unrecorded)
    }
    private func retainOSDI(_ resolved: OSDIResolvedInstance) throws {
        try storage.text(resolved.binding.modelName)
        try storage.text(resolved.binding.expectedDescriptorName)
        try storage.text(resolved.binding.artifact.digest.hexadecimalValue)
        try storage.text(resolved.binding.artifact.digest.algorithm.rawValue)
        try storage.text(resolved.binding.artifact.descriptor.role.rawValue)
        try storage.text(resolved.binding.artifact.descriptor.kind.rawValue)
        try storage.text(resolved.binding.artifact.descriptor.format.rawValue)
        try storage.retain(resolved.binding.modelParameters)
        try storage.retain(resolved.instanceParameters)
        try storage.retain(resolved.previousState)
        for assignments in [resolved.binding.modelParameters, resolved.instanceParameters] {
            for assignment in assignments {
                try storage.spend(); try storage.text(assignment.name)
                if case .string(let value) = assignment.value { try storage.text(value) }
            }
        }
    }
    private mutating func resolveNonMOS(_ job: FrontendComponentJob, scale: Double, expandModels: Bool,
        into builder: inout BoundedFrontendNetlist) throws -> FrontendResolvedComponent {
        let component = job.template.component, name = fullName(job)
        let emitter = NonMOSComponentEmitter()
        // FIXME(INCOMPLETE_IMPLEMENTATION): Other non-MOS devices lack an admitted parallel multiplier contract.
        // Pinned hierarchical X expansion reaches this before scalar evaluation or circuit publication.
        // Admit each family only after model/instance roles and DC/AC/transient/noise scaling are verified.
        if job.inheritedMultiplier != nil, component.type != .resistor, component.type != .capacitor {
            throw LoweringError.unsupportedFeature(feature: "Hierarchical multiplicity for \(component.type.rawValue) is not implemented")
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
        if component.type == .capacitor, selected != nil {
            if component.parameters["q"] != nil {
                throw LoweringError.invalidComponent(name: name, reason: "Charge capacitors cannot combine a source model")
            }
            if case .expression(let expression) = component.parameters["c"],
               try hasRuntime(expression, scope: job.template.scope) {
                throw LoweringError.invalidComponent(name: name, reason: "Runtime capacitance cannot combine a source model")
            }
        }
        let type = try componentType(component, model: selected?.model)
        var parameters: [String: ParameterValue] = [:]
        var model: ResolvedDeviceModel?
        var consumption: ModelConsumption = .modelFree
        if let selected {
            var values = try evaluateModel(selected, from: job.invocation)
            let overrides = compiled.scalarOverrides[name.lowercased()] ?? []
            for override in overrides where override.source.role == .model {
                guard case .real? = values[override.name] else {
                    throw LoweringError.invalidComponent(name: name, reason: "Model override is not a supplied scalar coefficient")
                }
                try storage.reserve(&values, values.count)
                values[override.name] = .real(override.source.value)
            }
            if compiled.captureSourceScalars {
                for (parameter, value) in try storage.entries(values) {
                    if case .real(let value) = value { try recordSourceScalar(instance: name, name: parameter, role: .model, value: value) }
                }
            }
            let resolved = ResolvedDeviceModel(name: selected.model.name, typeName: type,
                parameters: values, declarationID: selected.model.origin?.declarationID)
            try storage.text(resolved.name); try storage.text(resolved.typeName); try storage.text(resolved.declarationID)
            consumption = .selected(resolved)
            if component.type == .resistor || component.type == .capacitor { model = resolved }
            else if expandModels || component.type == .uniformRC {
                try storage.reserve(&parameters, values.count)
                for (key, value) in values { parameters[key] = value }
            }
        }
        let overrides = compiled.scalarOverrides[name.lowercased()] ?? []
        if selected == nil, overrides.contains(where: { $0.source.role == .model }) {
            throw LoweringError.invalidComponent(name: name, reason: "Model scalar override requires a selected source declaration")
        }
        var readNodes: [String] = [], readBranches: [String] = []
        for (key, value) in try storage.entries(component.parameters) {
            try storage.spend()
            if key.lowercased() == "m", job.inheritedMultiplier != nil { continue }
            if passiveUsesModel && key == (component.type == .resistor ? "r" : "c") { continue }
            try storage.reserve(&parameters, parameters.count + 1)
            if let override = overrides.first(where: { $0.source.role == .instance && $0.name == key.lowercased() }) {
                guard key != "ic", try retainedRuntimeExpression(value, key: key, component: component,
                    scope: job.template.scope) == nil else {
                    throw LoweringError.invalidComponent(name: name, reason: "Functional and initial-condition fields cannot use scalar perturbations")
                }
                parameters[key] = .real(override.source.value)
            } else if key == "control_source" {
                parameters[key] = try emitter.lowerControlSourceParameter(value, fullName: name, prefix: job.prefix)
            } else if key == "pwl", case .numericVector(let vector) = value,
                component.type == .voltageSource || component.type == .currentSource {
                parameters[key] = .realVector(vector)
            } else if let expression = try retainedRuntimeExpression(value, key: key,
                component: component, scope: job.template.scope) {
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
        if compiled.captureSourceScalars {
            for (parameter, value) in try storage.entries(parameters)
                where component.parameters[parameter] != nil && parameter != "ic" {
                if case .real(let value) = value { try recordSourceScalar(instance: name, name: parameter, role: .instance, value: value) }
            }
        }
        if let inherited = job.inheritedMultiplier {
            try storage.reserve(&parameters, parameters.count + 1)
            parameters["m"] = .real(try evaluateMOSProgram(inherited.program, invocation: job.invocation,
                lexicalScope: job.template.scope, from: compiled.snapshot, session: &evaluator))
        }
        if component.type == .resistor || component.type == .capacitor {
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
    private func retainedRuntimeExpression(_ value: ParsedParameterValue, key: String,
        component: ParsedComponent, scope: MOSScopeID) throws -> ParsedExpression? {
        if component.type == .capacitor, key == "q" {
            switch value {
            case .expression(let expression): return expression
            case .numeric(let value): return .literal(value)
            default: throw LoweringError.invalidComponent(name: component.name, reason: "Charge requires a numeric expression")
            }
        }
        guard case .expression(let expression) = value else { return nil }
        if component.type == .behavioral { return expression }
        if (component.type == .resistor && (key == "r" || key == "resistance"))
            || (component.type == .capacitor && key == "c") {
            if try hasRuntime(expression, scope: scope) { return expression }
        }
        return nil
    }
    private mutating func recordSourceScalar(instance: String, name: String,
        role: NetlistSourceScalarOverride.Role, value: Double) throws {
        guard compiled.captureSourceScalars else { return }
        try storage.text(instance); try storage.text(name)
        try storage.reserve(&sourceScalars, sourceScalars.count + 1)
        sourceScalars.append(try .init(instanceName: instance, parameterName: name, role: role, value: value))
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
        case .mosfet, .subcircuitInstance, .osdi: throw MOSResolutionFailure.invalidRequest
        }
    }
}
