import CoreSpiceEvaluationContracts
import CoreSpiceMOSContracts

/// Resolves one concrete MOS instance using the session's shared evaluation order.
public func resolveMOS(_ request: MOSResolutionRequest, from snapshot: MOSDeclarationSnapshot,
    schemas: any MOSModelSchemaProviding, session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) -> ResolvedMOSInstance {
    do { return try resolveAdmittedMOS(request, from: snapshot, schemas: schemas, session: &session) }
    catch { session.poison(error); throw error }
}

private func resolveAdmittedMOS(_ request: MOSResolutionRequest, from snapshot: MOSDeclarationSnapshot,
    schemas: any MOSModelSchemaProviding, session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) -> ResolvedMOSInstance {
    try session.beginRequest(request, from: snapshot)
    var rawValues: [MOSNumericParameter] = []
    var normalizedValues: [MOSNumericParameter] = []
    var candidates: [MOSCandidateEvidence] = []
    var rules: [MOSResolutionRule] = []
    var ownsRaw = false
    // Cleanup is allowed even after the first failure poisons evaluation.
    defer {
        if ownsRaw { do { try session.releaseStorage(for: rawValues) } catch { session.poison(error) } }
        do { try session.releaseStorage(for: normalizedValues) } catch { session.poison(error) }
        do { try session.releaseStorage(for: candidates) } catch { session.poison(error) }
        do { try session.releaseStorage(for: rules) } catch { session.poison(error) }
    }
    if let cached = try session.cachedInstance(for: request) { rawValues = cached }
    else {
        ownsRaw = true
        try session.reserve(&rawValues, required: request.bindings.count)
        for binding in request.bindings {
            try session.spend(.bindings, units: 1)
            let value = try evaluateMOSProgram(binding.program, invocation: request.scopeInstantiation,
                lexicalScope: request.scope, from: snapshot, session: &session)
            guard value.isFinite else { throw .nonFiniteValue(binding.symbol) }
            rawValues.append(MOSNumericParameter(symbol: binding.symbol, value: value))
        }
        try session.storeInstance(rawValues, for: request)
    }
    let raw = try MOSSelectionPolicy.rawGeometry(rawValues, snapshot: snapshot)
    try raw.validate()
    session.recordGeometry(raw: raw, normalized: nil, selection: nil)

    let ownership = try mosOwningCandidates(request, snapshot: snapshot, session: &session)
    let ids = ownership.ids
    let family = ownership.family
    guard ids.count <= session.limits.maximumCandidates else { throw .limitExceeded(.candidates) }
    try session.recordCandidates(ids.startIndex..<ids.endIndex, family: family)
    if family, raw.length == nil || raw.width == nil { throw .invalidGeometry("family dimensions") }
    // Duplicate declarations are rejected before evaluating any model slot in strict mode.
    if request.profile == .coreStrictV1 {
        for index in ids.indices {
            let model = try snapshot.declaration(ids[index])
            for earlier in ids.startIndex..<index {
                try session.spend(.candidates, units: 1)
                if try snapshot.declaration(ids[earlier]).name == model.name { throw .duplicateModel(model.name) }
            }
        }
    }
    let owner = try session.lexicalOwner(of: ownership.scope, from: request.scopeInstantiation)
    var selected: MOSModelDeclaration?
    var selectedRelease: MOSModelRelease?
    var selectedOrigin: MOSReleaseOrigin?
    var selectedSchema: MOSModelSchema?
    var selectedValues: [MOSNumericParameter] = []
    var normalized: MOSNormalizedGeometry?
    var selection: MOSSelectionGeometry?
    let useFingers = request.profile == .pinnedNgspiceNormalV1 && request.globalWidthPerFinger
    let positions = request.profile == .pinnedNgspiceNormalV1 && family ? stride(from: ids.endIndex - 1, through: ids.startIndex, by: -1) : stride(from: ids.startIndex, through: ids.endIndex - 1, by: 1)
    for position in positions {
        try session.spend(.candidates, units: 1)
        let model = try snapshot.declaration(ids[position])
        var discarded = false
        if request.profile == .pinnedNgspiceNormalV1 {
            for earlier in ids.startIndex..<position {
                try session.spend(.candidates, units: 1)
                if try snapshot.declaration(ids[earlier]).name == model.name { discarded = true; break }
            }
        }
        if discarded { continue }
        if let symbol = model.invalidCoefficient {
            try chargeSymbol(symbol, snapshot: snapshot, session: &session)
            throw .schema(.invalidValue(name: try snapshot.name(of: symbol)))
        }
        let (release, origin) = try MOSSelectionPolicy.release(model, profile: request.profile)
        let schema = try MOSSelectionPolicy.schema(release, provider: schemas)
        try validateAssignments(model.coefficients, role: .model, schema: schema,
            profile: request.profile, snapshot: snapshot, session: &session)
        try validateRawValues(rawValues, schema: schema, profile: request.profile,
            snapshot: snapshot, session: &session)
        let values = try modelValues(model, owner: owner, schema: schema,
            profile: request.profile, snapshot: snapshot, session: &session)
        normalizedValues.removeAll(keepingCapacity: true)
        try session.reserve(&normalizedValues, required: rawValues.count)
        for parameter in rawValues {
            try session.spend(.bindings, units: 1)
            try chargeSymbol(parameter.symbol, snapshot: snapshot, session: &session)
            let definition = try MOSSelectionPolicy.parameter(parameter.symbol, role: .instance, schema: schema, snapshot: snapshot)
            let value = try MOSSelectionPolicy.scale(parameter.value, definition: definition, factor: request.geometryScale)
            try install(parameter: MOSNumericParameter(symbol: parameter.symbol, value: value), definition: definition,
                into: &normalizedValues, role: .instance, schema: schema, snapshot: snapshot, session: &session)
        }
        let geometry = try MOSSelectionPolicy.rawGeometry(normalizedValues, snapshot: snapshot)
        let si = MOSNormalizedGeometry(length: geometry.length, width: geometry.width,
            drainArea: geometry.drainArea, sourceArea: geometry.sourceArea,
            drainPerimeter: geometry.drainPerimeter, sourcePerimeter: geometry.sourcePerimeter)
        try si.validate()
        let nf = try MOSSelectionPolicy.value("nf", in: rawValues, snapshot: snapshot) ?? 1
        let width: Double?
        if useFingers, let rawWidth = raw.width {
            let divided = rawWidth / nf
            guard divided.isFinite, divided > 0 else { throw .invalidGeometry("w/nf") }
            do { width = try MOSParameterScale.length.apply(to: divided, scale: request.geometryScale) }
            catch { throw .schema(error) }
        } else { width = si.width }
        let choice = MOSSelectionGeometry(length: si.length, width: width, fingerDivisor: useFingers ? nf : 1)
        session.recordGeometry(raw: raw, normalized: si, selection: choice)
        let bounds = family ? try MOSSelectionPolicy.bounds(values, snapshot: snapshot) : nil
        let matches: Bool
        if let bounds { matches = try MOSSelectionPolicy.matches(bounds, geometry: choice, profile: request.profile, declaration: model.id) }
        else { matches = true }
        let disposition: MOSCandidateDisposition = matches ? .selected : (bounds?.missingMask != 0 ? .missingBounds : .outsideBounds)
        let evidence = MOSCandidateEvidence(declaration: model.id, disposition: disposition, bounds: bounds)
        try session.reserve(&candidates, required: candidates.count + 1)
        candidates.append(evidence); session.recordCandidate(evidence)
        if matches {
            if selected != nil { throw .ambiguousModel(request.modelReference) }
            selected = model; selectedRelease = release; selectedOrigin = origin
            selectedSchema = schema; selectedValues = values; normalized = si; selection = choice
            if request.profile == .pinnedNgspiceNormalV1 || !family { break }
        }
    }
    guard let model = selected, let release = selectedRelease, let origin = selectedOrigin,
          let schema = selectedSchema, let si = normalized, let choice = selection else { throw .noMatchingBin(request.modelReference) }
    // Strict traversal may end at an excluded candidate; rebuild the selected instance's exact schema buffer.
    normalizedValues.removeAll(keepingCapacity: true)
    for parameter in rawValues {
        try chargeSymbol(parameter.symbol, snapshot: snapshot, session: &session)
        let definition = try MOSSelectionPolicy.parameter(parameter.symbol, role: .instance, schema: schema, snapshot: snapshot)
        let value = try MOSSelectionPolicy.scale(parameter.value, definition: definition, factor: request.geometryScale)
        try install(parameter: MOSNumericParameter(symbol: parameter.symbol, value: value), definition: definition,
            into: &normalizedValues, role: .instance, schema: schema, snapshot: snapshot, session: &session)
    }
    try session.reserve(&rules, required: MOSSelectionPolicy.ruleCount)
    for index in 0..<MOSSelectionPolicy.ruleCount {
        rules.append(MOSSelectionPolicy.rule(at: index, family: family, profile: request.profile, widthPerFinger: useFingers))
    }
    let limits = session.limits
    let environment = session.environment?.identity
    return try session.withValidationBudget { (workBudget: inout MOSStorageBudget) throws(MOSResolutionFailure) -> ResolvedMOSInstance in
        try ResolvedMOSInstance(evaluationEnvironment: environment, identitySpace: snapshot.identitySpace, source: model.source,
        instanceSource: request.source, selectedName: model.name, symbolNames: snapshot.symbols,
        scope: model.scope, scopeInstantiation: request.scopeInstantiation, instance: request.instance,
        declaration: model.id, polarity: model.polarity, release: release, releaseOrigin: origin,
        schema: schema.identity, modelCoefficients: selectedValues, instanceParameters: normalizedValues,
        rawGeometry: raw, normalizedGeometry: si, selectionGeometry: choice, profile: request.profile,
        geometryScale: request.geometryScale,
        rules: rules, candidates: candidates, limits: limits, workBudget: &workBudget)
    }
}

package func mosOwningCandidates(_ request: MOSResolutionRequest, snapshot: MOSDeclarationSnapshot,
    session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) -> (ids: ArraySlice<MOSDeclarationID>, scope: MOSScopeID, family: Bool) {
    var scope: MOSScopeID? = request.scope
    var depth = 0
    while let current = scope {
        try session.spend(.scopes, units: 1)
        depth += 1
        guard depth <= session.limits.maximumScopeDepth else { throw .limitExceeded(.scopeDepth) }
        let exact = snapshot.exact(named: request.modelReference, in: current)
        if !exact.isEmpty { return (exact, current, false) }
        let family = snapshot.family(named: request.modelReference, in: current)
        if !family.isEmpty { return (family, current, true) }
        scope = try snapshot.scope(current).parent
    }
    throw .missingModel(request.modelReference)
}

private func validateAssignments(_ bindings: [MOSExpressionBinding], role: MOSParameterRole,
    schema: MOSModelSchema, profile: MOSInputProfile, snapshot: MOSDeclarationSnapshot,
    session: inout MOSEvaluationSession) throws(MOSResolutionFailure) {
    for (index, binding) in bindings.enumerated() {
        try session.spend(.bindings, units: 1)
        try chargeSymbol(binding.symbol, snapshot: snapshot, session: &session)
        let definition = try MOSSelectionPolicy.parameter(binding.symbol, role: role, schema: schema, snapshot: snapshot)
        if profile == .coreStrictV1 {
            for prior in bindings[..<index] {
                try session.spend(.bindings, units: 1)
                try chargeSymbol(prior.symbol, snapshot: snapshot, session: &session)
                let earlier = try MOSSelectionPolicy.parameter(prior.symbol, role: role, schema: schema, snapshot: snapshot)
                if earlier.canonicalName == definition.canonicalName { throw .duplicateParameter(binding.symbol) }
            }
        }
    }
}

private func validateRawValues(_ values: [MOSNumericParameter], schema: MOSModelSchema,
    profile: MOSInputProfile, snapshot: MOSDeclarationSnapshot, session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) {
    for (index, value) in values.enumerated() {
        try session.spend(.bindings, units: 1)
        try chargeSymbol(value.symbol, snapshot: snapshot, session: &session)
        let definition = try MOSSelectionPolicy.parameter(value.symbol, role: .instance, schema: schema, snapshot: snapshot)
        try MOSSelectionPolicy.validate(value.value, definition: definition)
        if profile == .coreStrictV1 {
            for prior in values[..<index] {
                try session.spend(.bindings, units: 1)
                try chargeSymbol(prior.symbol, snapshot: snapshot, session: &session)
                let earlier = try MOSSelectionPolicy.parameter(prior.symbol, role: .instance, schema: schema, snapshot: snapshot)
                if earlier.canonicalName == definition.canonicalName { throw .duplicateParameter(value.symbol) }
            }
        }
    }
}

private func modelValues(_ model: MOSModelDeclaration, owner: UInt64, schema: MOSModelSchema,
    profile: MOSInputProfile, snapshot: MOSDeclarationSnapshot, session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) -> [MOSNumericParameter] {
    if let values = try session.cachedModel(declaration: model.id, invocation: owner, profile: profile) {
        for value in values {
            try session.spend(.bindings, units: 1)
            try chargeSymbol(value.symbol, snapshot: snapshot, session: &session)
            let definition = try MOSSelectionPolicy.parameter(value.symbol, role: .model, schema: schema, snapshot: snapshot)
            try MOSSelectionPolicy.validate(value.value, definition: definition)
        }
        return values
    }
    var values: [MOSNumericParameter] = []
    defer { do { try session.releaseStorage(for: values) } catch { session.poison(error) } }
    try session.reserve(&values, required: model.coefficients.count)
    for binding in model.coefficients {
        try session.spend(.bindings, units: 1)
        try chargeSymbol(binding.symbol, snapshot: snapshot, session: &session)
        let definition = try MOSSelectionPolicy.parameter(binding.symbol, role: .model, schema: schema, snapshot: snapshot)
        let value = try evaluateMOSProgram(binding.program, invocation: owner, lexicalScope: model.scope,
            from: snapshot, session: &session)
        try MOSSelectionPolicy.validate(value, definition: definition)
        try install(parameter: MOSNumericParameter(symbol: binding.symbol, value: value), definition: definition,
            into: &values, role: .model, schema: schema, snapshot: snapshot, session: &session)
    }
    try session.storeModel(values, declaration: model.id, invocation: owner, profile: profile)
    return values
}

private func install(parameter: MOSNumericParameter, definition: MOSParameterDefinition,
    into values: inout [MOSNumericParameter], role: MOSParameterRole, schema: MOSModelSchema,
    snapshot: MOSDeclarationSnapshot, session: inout MOSEvaluationSession) throws(MOSResolutionFailure) {
    for index in values.indices {
        try session.spend(.bindings, units: 1)
        try chargeSymbol(values[index].symbol, snapshot: snapshot, session: &session)
        let previous = try MOSSelectionPolicy.parameter(values[index].symbol, role: role, schema: schema, snapshot: snapshot)
        if previous.canonicalName == definition.canonicalName { values[index] = parameter; return }
    }
    values.append(parameter)
}

private func chargeSymbol(_ symbol: MOSSymbolID, snapshot: MOSDeclarationSnapshot,
    session: inout MOSEvaluationSession) throws(MOSResolutionFailure) {
    let name = try snapshot.name(of: symbol)
    try session.spend(.identifierBytes, units: UInt64(name.utf8.count))
}
