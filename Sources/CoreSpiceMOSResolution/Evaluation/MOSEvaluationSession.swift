import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts

/// Exclusive deterministic evaluation state shared by numeric consumers and MOS selection.
public struct MOSEvaluationSession: ~Copyable {
    public let snapshot: MOSDeclarationSnapshot
    public let graph: MOSInvocationGraph
    public let seed: UInt64
    public let limits: MOSResolutionLimits
    public private(set) var profile: MOSInputProfile?
    public var evaluationSteps: UInt64 { budget.steps }
    public private(set) var randomDraws: UInt64 = 0
    public var retainedBytes: UInt64 { budget.bytes }
    public var peakOwnedBufferBytes: UInt64 { budget.peakBytes }
    public private(set) var failureDiagnostic: MOSResolutionDiagnostic?
    public static var evaluatorVersion: String { "CoreSpice.MOSEvaluator.v2.temperature-freeze" }
    public static var randomGeneratorVersion: String { MOSCoreRandom.version }

    public private(set) var environment: EvaluationEnvironment?
    package var activeCondition: EvaluationCondition?
    package var bootstrapAmbient: TemperatureKelvin?

    package mutating func freezeEnvironment(_ value: EvaluationEnvironment) {
        environment = value; activeCondition = nil; bootstrapAmbient = nil
        attempt.conditionSource = nil; attempt.variableBytes = 0; attempt.isTruncated = false
    }
    package func scalarAmbient() throws(MOSResolutionFailure) -> Double {
        let temperature: TemperatureKelvin
        if let environment { temperature = environment.ambient }
        else if let bootstrapAmbient { temperature = bootstrapAmbient }
        else if let activeCondition { throw .conditionCycle(activeCondition) }
        else { throw .environmentUnavailable }
        do { return try temperature.celsius().value }
        catch { throw .invalidTemperature(activeCondition ?? .ambient, error) }
    }

    private var budget: MOSStorageBudget
    private var random: MOSCoreRandom
    private var rootVisits: [MOSRootVisit] = []
    private var bindings: [MOSInvocationBindingKey: Double] = [:]
    private var models: [MOSModelEvaluationKey: [MOSNumericParameter]] = [:]
    private var instances: [MOSInstanceEvaluationKey: MOSInstanceEvaluationRecord] = [:]
    private var attempt = MOSEvaluationAttempt()
    private let diagnosticHeaderBytes: UInt64
    private let diagnosticDependencyBytes: UInt64
    private let diagnosticCandidateBytes: UInt64

    public init(snapshot: MOSDeclarationSnapshot, graph: MOSInvocationGraph, seed: UInt64,
                limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil)
        throws(MOSResolutionFailure) {
        guard graph.snapshot.sameStorage(as: snapshot) else { throw .conditionMismatch }
        guard snapshot.symbols.count <= limits.maximumSymbols else { throw .limitExceeded(.symbols) }
        guard snapshot.scopes.count <= limits.maximumScopes else { throw .limitExceeded(.scopes) }
        guard snapshot.declarations.count <= limits.maximumDeclarations else { throw .limitExceeded(.declarations) }
        guard snapshot.programs.count <= limits.maximumPrograms else { throw .limitExceeded(.programs) }
        guard snapshot.bindings.count <= limits.maximumBindings else { throw .limitExceeded(.bindings) }
        guard snapshot.functions.count <= limits.maximumFunctions else { throw .limitExceeded(.functions) }
        guard graph.invocations.count <= limits.maximumInvocations else { throw .limitExceeded(.invocations) }
        guard graph.finalBindings.count <= limits.maximumInvocationBindings else { throw .limitExceeded(.invocationBindings) }
        guard graph.maximumDepth <= limits.maximumScopeDepth else { throw .limitExceeded(.scopeDepth) }
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps, control: control)
        try budget.add(graph.retainedBytes)
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        // Reserve diagnostic capacity before any evaluation can consume the ordinary ledger.
        let header = UInt64(MemoryLayout<MOSResolutionDiagnostic>.stride)
        guard header <= limits.maximumDiagnosticBytes else { throw .limitExceeded(.diagnosticBytes) }
        try budget.add(limits.maximumDiagnosticBytes)
        var attempt = MOSEvaluationAttempt()
        let stride = UInt64(MemoryLayout<MOSCandidateEvidence>.stride)
        let count = min(UInt64(limits.maximumCandidates), (limits.maximumDiagnosticBytes - header) / 2 / stride)
        attempt.candidates.reserveCapacity(Int(count))
        let candidateBytes = try MOSStorageBudget.capacityBytes(attempt.candidates.capacity, of: MOSCandidateEvidence.self)
        guard candidateBytes <= limits.maximumDiagnosticBytes - header else { throw .limitExceeded(.diagnosticBytes) }
        let dependencyStride = UInt64(MemoryLayout<MOSConditionDependency>.stride)
        let dependencyCount = min(UInt64(limits.maximumExpressionDepth),
            (limits.maximumDiagnosticBytes - header - candidateBytes) / 2 / dependencyStride)
        attempt.conditionDependencies.reserveCapacity(Int(dependencyCount))
        let dependencyBytes = try MOSStorageBudget.capacityBytes(attempt.conditionDependencies.capacity, of: MOSConditionDependency.self)
        guard dependencyBytes <= limits.maximumDiagnosticBytes - header - candidateBytes else { throw .limitExceeded(.diagnosticBytes) }
        self.diagnosticDependencyBytes = dependencyBytes
        self.snapshot = snapshot; self.graph = graph; self.seed = seed; self.limits = limits
        self.budget = budget; self.random = MOSCoreRandom(seed: seed); self.attempt = attempt
        self.diagnosticHeaderBytes = header; self.diagnosticCandidateBytes = candidateBytes
    }

    public consuming func finishProvenance() -> MOSEvaluationProvenance {
        MOSEvaluationProvenance(environment: environment, seed: seed, randomGeneratorVersion: MOSCoreRandom.version,
            evaluatorVersion: Self.evaluatorVersion, randomDraws: randomDraws, rootVisits: rootVisits)
    }

    package mutating func recordRootVisit(_ visit: MOSRootVisit) throws(MOSResolutionFailure) {
        try spend(.evaluationSteps)
        // Move the unique array out while calling the generic session reservation operation.
        var visits: [MOSRootVisit] = []
        swap(&visits, &rootVisits)
        defer { swap(&visits, &rootVisits) }
        try reserve(&visits, required: visits.count + 1)
        visits.append(visit)
    }

    package func checkHealthy() throws(MOSResolutionFailure) {
        guard failureDiagnostic == nil else { throw .poisonedSession }
    }

    package mutating func withValidationBudget<Result>(
        _ body: (inout MOSStorageBudget) throws(MOSResolutionFailure) -> Result
    ) throws(MOSResolutionFailure) -> Result {
        try checkHealthy()
        do throws(MOSResolutionFailure) { return try body(&budget) }
        catch { poison(error); throw error }
    }

    /// Checks lexical visibility and resolves its concrete owner, charging every ancestry hop.
    package mutating func lexicalOwner(of scope: MOSScopeID, from invocation: UInt64)
        throws(MOSResolutionFailure) -> UInt64 {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            _ = try snapshot.scope(scope)
            var lexical: MOSScopeID? = try graph.invocation(invocation).scope
            var visible = false
            while let current = lexical {
                try spend(.evaluationSteps)
                if current == scope { visible = true; break }
                lexical = try snapshot.scope(current).parent
            }
            guard visible else { throw .invalidScope }
            var caller: UInt64? = invocation
            while let current = caller {
                try spend(.evaluationSteps)
                let entry = try graph.invocation(current)
                if entry.scope == scope { return current }
                caller = entry.callerInvocationID
            }
            throw .invalidInvocation(invocation)
        } catch { poison(error); throw error }
    }

    package mutating func spend(_ kind: MOSResolutionWork, units: UInt64 = 1) throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            guard units <= limits.maximumEvaluationSteps - budget.steps else { throw MOSResolutionFailure.limitExceeded(.evaluationSteps) }
            for _ in 0..<units { try budget.spend() }
            if kind != .evaluationSteps { try budget.control?.charge(kind, units: units) }
        } catch { poison(error); throw error }
    }

    package mutating func reserve<Element>(_ buffer: inout [Element], required: Int) throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            guard required > buffer.capacity else { return }
            guard UInt64(required) <= limits.maximumEvaluationSteps - budget.steps else { throw MOSResolutionFailure.limitExceeded(.evaluationSteps) }
            let requestedBytes = try MOSStorageBudget.growthBytes(buffer, required: required)
            try budget.checkAdding(requestedBytes)
            let oldBytes = try MOSStorageBudget.capacityBytes(buffer.capacity, of: Element.self)
            // Keep the old buffer intact if the allocator's returned capacity fails admission.
            var grown = buffer
            grown.reserveCapacity(Int(requestedBytes / UInt64(MemoryLayout<Element>.stride)))
            try budget.add(MOSStorageBudget.capacityBytes(grown.capacity, of: Element.self))
            budget.release(oldBytes); buffer = grown
        }
        catch { poison(error); throw error }
    }

    package mutating func releaseStorage<Element>(for buffer: [Element]) throws(MOSResolutionFailure) {
        // Cleanup remains legal after poison and neither allocates nor checks cancellation.
        let bytes = try MOSStorageBudget.capacityBytes(buffer.capacity, of: Element.self)
        guard bytes <= budget.bytes else { throw .invalidRequest }
        budget.release(bytes)
    }

    package mutating func releaseEvaluationStorage<Element>(for buffer: [Element]) {
        // Capacities were admitted with this exact element type and cannot overflow here.
        budget.release(UInt64(buffer.capacity) * UInt64(MemoryLayout<Element>.stride))
    }

    package mutating func beginRequest(_ request: MOSResolutionRequest, from snapshot: MOSDeclarationSnapshot)
        throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            // Capture only opaque request identity before validating any snapshot-local IDs.
            attempt.instance = nil; attempt.instanceSource = nil
            attempt.invocation = request.scopeInstantiation; attempt.scope = request.scope
            attempt.modelReference = request.modelReference; attempt.binding = nil; attempt.program = nil
            attempt.rawGeometry = nil; attempt.normalizedGeometry = nil; attempt.selectionGeometry = nil
            attempt.candidateRange = nil; attempt.candidateRangeIsFamily = false
            attempt.candidates.removeAll(keepingCapacity: true)
            attempt.variableBytes = 0; attempt.isTruncated = false
            let textBytes = UInt64(request.instance.utf8.count) + sourceBytes(request.source)
            if textBytes <= limits.maximumDiagnosticBytes - diagnosticHeaderBytes - diagnosticCandidateBytes - diagnosticDependencyBytes {
                attempt.instance = request.instance; attempt.instanceSource = request.source
                attempt.variableBytes = textBytes
            } else { attempt.isTruncated = true }
            try validateRequest(request, from: snapshot)
            let key = MOSInstanceEvaluationKey(instance: request.instance, invocation: request.scopeInstantiation)
            if let existing = instances[key] {
                guard existing.request == request else { throw MOSResolutionFailure.conditionMismatch }
            } else {
                try admitCacheEntry()
                try budget.add(request.retainedBytes)
                if instances.count == instances.capacity { try reserveMOSCache(&instances, required: instances.count + 1, budget: &budget) }
                instances[key] = MOSInstanceEvaluationRecord(request: request, values: nil)
            }
            profile = request.profile
        } catch { poison(error); throw error }
    }

    private mutating func validateRequest(_ request: MOSResolutionRequest, from snapshot: MOSDeclarationSnapshot)
        throws(MOSResolutionFailure) {
        try spend(.evaluationSteps)
        guard self.snapshot.sameStorage(as: snapshot), request.seed == seed,
              profile == nil || profile == request.profile else { throw .conditionMismatch }
        guard try graph.invocation(request.scopeInstantiation).scope == request.scope else { throw .conditionMismatch }
        _ = try snapshot.name(of: request.modelReference)
        for _ in request.instance.utf8 { try spend(.evaluationSteps) }
        if let text = request.source?.captureID { for _ in text.utf8 { try spend(.evaluationSteps) } }
        if let text = request.source?.path { for _ in text.utf8 { try spend(.evaluationSteps) } }
        for binding in request.bindings {
            try spend(.evaluationSteps)
            _ = try snapshot.name(of: binding.symbol); _ = try snapshot.program(binding.program)
        }
    }

    package mutating func cachedInstance(for request: MOSResolutionRequest)
        throws(MOSResolutionFailure) -> [MOSNumericParameter]? {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            try validateRequest(request, from: snapshot)
            let key = MOSInstanceEvaluationKey(instance: request.instance, invocation: request.scopeInstantiation)
            guard let record = instances[key], record.request == request else { throw MOSResolutionFailure.conditionMismatch }
            return record.values
        } catch { poison(error); throw error }
    }

    package mutating func storeInstance(_ values: [MOSNumericParameter], for request: MOSResolutionRequest)
        throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            try validateRequest(request, from: snapshot)
            let key = MOSInstanceEvaluationKey(instance: request.instance, invocation: request.scopeInstantiation)
            guard let record = instances[key], record.request == request else { throw MOSResolutionFailure.conditionMismatch }
            if let existing = record.values {
                guard existing == values else { throw MOSResolutionFailure.conditionMismatch }
                return
            }
            try validateValues(values); try budget.addArray(values)
            instances[key] = MOSInstanceEvaluationRecord(request: request, values: values)
        } catch { poison(error); throw error }
    }

    package mutating func cachedModel(declaration: MOSDeclarationID, invocation: UInt64, profile: MOSInputProfile)
        throws(MOSResolutionFailure) -> [MOSNumericParameter]? {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            try validateModel(declaration, invocation: invocation, profile: profile)
            return models[MOSModelEvaluationKey(declaration: declaration, invocation: invocation, profile: profile)]
        } catch { poison(error); throw error }
    }

    package mutating func storeModel(_ values: [MOSNumericParameter], declaration: MOSDeclarationID,
                                    invocation: UInt64, profile: MOSInputProfile) throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            try validateModel(declaration, invocation: invocation, profile: profile)
            let key = MOSModelEvaluationKey(declaration: declaration, invocation: invocation, profile: profile)
            if let existing = models[key] {
                guard existing == values else { throw MOSResolutionFailure.conditionMismatch }
                return
            }
            try validateValues(values); try admitCacheEntry(); try budget.addArray(values)
            if models.count == models.capacity { try reserveMOSCache(&models, required: models.count + 1, budget: &budget) }
            models[key] = values
        } catch { poison(error); throw error }
    }

    private mutating func validateModel(_ declaration: MOSDeclarationID, invocation: UInt64, profile: MOSInputProfile)
        throws(MOSResolutionFailure) {
        try spend(.evaluationSteps)
        guard self.profile == profile, try graph.invocation(invocation).scope == snapshot.declaration(declaration).scope else {
            throw .conditionMismatch
        }
    }

    private mutating func validateValues(_ values: [MOSNumericParameter]) throws(MOSResolutionFailure) {
        for (index, value) in values.enumerated() {
            try spend(.evaluationSteps); _ = try snapshot.name(of: value.symbol)
            guard value.value.isFinite else { throw .nonFiniteValue(value.symbol) }
            for previous in values[..<index] {
                try spend(.evaluationSteps)
                guard previous.symbol != value.symbol else { throw .duplicateParameter(value.symbol) }
            }
        }
    }

    private func admitCacheEntry() throws(MOSResolutionFailure) {
        guard bindings.count + models.count + instances.count < limits.maximumCacheEntries else { throw .limitExceeded(.cacheEntries) }
    }

    package func cachedBinding(_ key: MOSInvocationBindingKey) -> Double? { bindings[key] }
    package mutating func storeBinding(_ value: Double, for key: MOSInvocationBindingKey) throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            guard value.isFinite else { throw MOSResolutionFailure.nonFiniteValue(key.symbol) }
            if bindings[key] == nil {
                try admitCacheEntry()
                if bindings.count == bindings.capacity { try reserveMOSCache(&bindings, required: bindings.count + 1, budget: &budget) }
                bindings[key] = value
            }
        } catch { poison(error); throw error }
    }

    package mutating func drawRandom() throws(MOSResolutionFailure) -> Double {
        try spend(.evaluationSteps)
        guard randomDraws < UInt64.max else { throw .arithmeticOverflow }
        randomDraws += 1
        return random.next()
    }

    package mutating func recordExpression(binding: MOSSymbolID?, program: MOSProgramID?, invocation: UInt64, scope: MOSScopeID) {
        guard failureDiagnostic == nil else { return }
        attempt.binding = binding; attempt.program = program
        if attempt.instance == nil { attempt.invocation = invocation; attempt.scope = scope }
    }

    package mutating func recordGeometry(raw: MOSInputGeometry?, normalized: MOSNormalizedGeometry?, selection: MOSSelectionGeometry?) {
        guard failureDiagnostic == nil else { return }
        attempt.rawGeometry = raw; attempt.normalizedGeometry = normalized; attempt.selectionGeometry = selection
    }

    package mutating func recordCandidates(_ range: Range<Int>, family: Bool) throws(MOSResolutionFailure) {
        try checkHealthy()
        do throws(MOSResolutionFailure) {
            let count = family ? snapshot.familyDeclarationIDs.count : snapshot.exactDeclarationIDs.count
            guard range.lowerBound >= 0, range.upperBound <= count else { throw MOSResolutionFailure.invalidRequest }
            attempt.candidateRange = range; attempt.candidateRangeIsFamily = family
        } catch { poison(error); throw error }
    }

    package mutating func recordCandidate(_ candidate: MOSCandidateEvidence) {
        guard failureDiagnostic == nil else { return }
        if attempt.candidates.count < attempt.candidates.capacity, attempt.candidates.count < limits.maximumCandidates { attempt.candidates.append(candidate) }
        else { attempt.isTruncated = true }
    }

    package mutating func beginCondition(_ condition: EvaluationCondition, source: MOSSourceOccurrence?) {
        activeCondition = condition
        attempt.program = nil; attempt.binding = nil; attempt.scope = nil; attempt.invocation = nil
        attempt.conditionSource = nil; attempt.variableBytes = 0; attempt.isTruncated = false
        let bytes = sourceBytes(source)
        if bytes <= limits.maximumDiagnosticBytes - diagnosticHeaderBytes - diagnosticCandidateBytes - diagnosticDependencyBytes {
            attempt.conditionSource = source; attempt.variableBytes = bytes
        } else { attempt.isTruncated = true }
    }

    package mutating func recordConditionPath(_ keys: [MOSInvocationBindingKey]) {
        guard failureDiagnostic == nil else { return }
        attempt.conditionDependencies.removeAll(keepingCapacity: true)
        for key in keys {
            guard attempt.conditionDependencies.count < attempt.conditionDependencies.capacity else {
                attempt.isTruncated = true; break
            }
            attempt.conditionDependencies.append(.init(invocation: key.invocation, symbol: key.symbol))
        }
    }

    package mutating func poison(_ cause: MOSResolutionFailure) {
        guard failureDiagnostic == nil else { return }
        failureDiagnostic = MOSResolutionDiagnostic(condition: activeCondition, conditionSource: attempt.conditionSource, conditionDependencies: attempt.conditionDependencies, snapshot: snapshot, cause: cause,
            instance: attempt.instance, instanceSource: attempt.instanceSource, invocation: attempt.invocation,
            scope: attempt.scope, modelReference: attempt.modelReference, binding: attempt.binding,
            program: attempt.program, rawGeometry: attempt.rawGeometry, normalizedGeometry: attempt.normalizedGeometry,
            selectionGeometry: attempt.selectionGeometry, candidateRange: attempt.candidateRange,
            candidateRangeIsFamily: attempt.candidateRangeIsFamily, candidates: attempt.candidates,
            isTruncated: attempt.isTruncated)
    }

    private func sourceBytes(_ source: MOSSourceOccurrence?) -> UInt64 {
        guard let source else { return 0 }
        return UInt64(source.captureID?.utf8.count ?? 0) + UInt64(source.path?.utf8.count ?? 0)
    }
}

private func reserveMOSCache<Key: Hashable, Value>(_ buffer: inout [Key: Value], required: Int,
                                                  budget: inout MOSStorageBudget) throws(MOSResolutionFailure) {
    let requested = max(required, buffer.capacity)
    try budget.checkAdding(MOSStorageBudget.capacityBytes(requested, of: (Key, Value).self))
    let oldBytes = try MOSStorageBudget.capacityBytes(buffer.capacity, of: (Key, Value).self)
    var grown = buffer
    grown.reserveCapacity(requested)
    try budget.add(MOSStorageBudget.capacityBytes(grown.capacity, of: (Key, Value).self))
    budget.release(oldBytes); buffer = grown
}
