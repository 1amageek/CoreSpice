import CoreSpiceMOSContracts

/// Checks held evidence against the exact immutable snapshot without expression evaluation.
public func inspectResolvedMOS(_ result: ResolvedMOSInstance, from snapshot: MOSDeclarationSnapshot,
    limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil)
    throws(MOSResolutionFailure) -> MOSResolvedInspection {
    // No snapshot-local ID, source or name is dereferenced before this capability check.
    guard snapshot.identitySpace.sameStorage(as: result.identitySpace) else { throw .conditionMismatch }
    var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
        maximumSteps: limits.maximumEvaluationSteps, control: control)
    try budget.spend()
    try budget.add(result.retainedBytes)
    guard !result.candidates.isEmpty, result.candidates.count <= limits.maximumCandidates else { throw .invalidResolvedInstance }
    let selected = try snapshot.declaration(result.declaration)
    guard selected.name == result.selectedName, selected.polarity == result.polarity,
          selected.source == result.source, snapshot.symbols.count == result.symbolNames.count else { throw .invalidResolvedInstance }
    for index in snapshot.symbols.indices {
        for _ in snapshot.symbols[index].utf8 { try budget.spend() }
        for _ in result.symbolNames[index].utf8 { try budget.spend() }
        guard snapshot.symbols[index] == result.symbolNames[index] else { throw .invalidResolvedInstance }
    }
    let (release, origin) = try MOSSelectionPolicy.release(selected, profile: result.profile)
    guard release == result.release, origin == result.releaseOrigin, release.schemaIdentity == result.schema else { throw .invalidResolvedInstance }
    let schema = MOSModelSchema(release: release)
    try inspectParameters(result.modelCoefficients, role: .model, schema: schema, snapshot: snapshot, budget: &budget)
    try inspectParameters(result.instanceParameters, role: .instance, schema: schema, snapshot: snapshot, budget: &budget)
    try result.rawGeometry.validate(); try result.normalizedGeometry.validate()
    guard result.geometryScale.isFinite, result.geometryScale > 0 else { throw .invalidResolvedInstance }
    func scaled(_ value: Double?, kind: MOSParameterScale) throws(MOSResolutionFailure) -> Double? {
        guard let value else { return nil }
        try budget.spend()
        do { return try kind.apply(to: value, scale: result.geometryScale) }
        catch { throw .invalidResolvedInstance }
    }
    guard try scaled(result.rawGeometry.length, kind: .length) == result.normalizedGeometry.length,
          try scaled(result.rawGeometry.width, kind: .length) == result.normalizedGeometry.width,
          try scaled(result.rawGeometry.drainArea, kind: .area) == result.normalizedGeometry.drainArea,
          try scaled(result.rawGeometry.sourceArea, kind: .area) == result.normalizedGeometry.sourceArea,
          try scaled(result.rawGeometry.drainPerimeter, kind: .length) == result.normalizedGeometry.drainPerimeter,
          try scaled(result.rawGeometry.sourcePerimeter, kind: .length) == result.normalizedGeometry.sourcePerimeter else {
        throw .invalidResolvedInstance
    }
    guard result.selectionGeometry.length == result.normalizedGeometry.length,
          result.selectionGeometry.fingerDivisor.isFinite, result.selectionGeometry.fingerDivisor >= 1 else { throw .invalidResolvedInstance }
    let perFinger = result.rules.contains(.widthPerFinger)
    if !perFinger {
        guard result.selectionGeometry.width == result.normalizedGeometry.width,
              result.selectionGeometry.fingerDivisor == 1 else { throw .invalidResolvedInstance }
    } else {
        guard result.profile == .pinnedNgspiceNormalV1 else { throw .invalidResolvedInstance }
        let nf = try MOSSelectionPolicy.value("nf", in: result.instanceParameters, snapshot: snapshot) ?? 1
        guard nf == result.selectionGeometry.fingerDivisor else { throw .invalidResolvedInstance }
        if let rawWidth = result.rawGeometry.width, let selectedWidth = result.selectionGeometry.width {
            let divided = rawWidth / nf
            guard divided.isFinite, divided > 0,
                  try scaled(divided, kind: .length) == selectedWidth else { throw .invalidResolvedInstance }
        } else if result.rawGeometry.width != nil || result.normalizedGeometry.width != nil || result.selectionGeometry.width != nil {
            throw .invalidResolvedInstance
        }
    }
    let geometry = try MOSSelectionPolicy.rawGeometry(result.instanceParameters, snapshot: snapshot)
    guard geometry.length == result.normalizedGeometry.length, geometry.width == result.normalizedGeometry.width,
          geometry.drainArea == result.normalizedGeometry.drainArea, geometry.sourceArea == result.normalizedGeometry.sourceArea,
          geometry.drainPerimeter == result.normalizedGeometry.drainPerimeter,
          geometry.sourcePerimeter == result.normalizedGeometry.sourcePerimeter else { throw .invalidResolvedInstance }
    let family = result.candidates[0].bounds != nil
    let reference: MOSSymbolID
    if family { guard let name = selected.family else { throw .invalidResolvedInstance }; reference = name }
    else { reference = selected.name }
    var current: MOSScopeID? = result.scope
    var owner: MOSScopeID?
    var ids: ArraySlice<MOSDeclarationID> = snapshot.exactDeclarationIDs[0..<0]
    var depth = 0
    while let scope = current {
        try budget.spend(); depth += 1
        guard depth <= limits.maximumScopeDepth else { throw .limitExceeded(.scopeDepth) }
        let exact = snapshot.exact(named: reference, in: scope)
        if !exact.isEmpty { guard !family else { throw .invalidResolvedInstance }; owner = scope; ids = exact; break }
        let bins = snapshot.family(named: reference, in: scope)
        if !bins.isEmpty { guard family else { throw .invalidResolvedInstance }; owner = scope; ids = bins; break }
        current = try snapshot.scope(scope).parent
    }
    guard owner == selected.scope, ids.count <= limits.maximumCandidates,
          result.rules.count == MOSSelectionPolicy.ruleCount else { throw .invalidResolvedInstance }
    for index in result.rules.indices {
        try budget.spend()
        guard result.rules[index] == MOSSelectionPolicy.rule(at: index, family: family,
            profile: result.profile, widthPerFinger: perFinger) else { throw .invalidResolvedInstance }
    }
    if result.profile == .coreStrictV1 {
        for index in ids.indices {
            let name = try snapshot.declaration(ids[index]).name
            for prior in ids.startIndex..<index {
                try budget.spend()
                guard try snapshot.declaration(ids[prior]).name != name else { throw .invalidResolvedInstance }
            }
        }
    }
    var visit = 0
    var selectedCount = 0
    let positions = result.profile == .pinnedNgspiceNormalV1 && family ? stride(from: ids.endIndex - 1, through: ids.startIndex, by: -1) : stride(from: ids.startIndex, through: ids.endIndex - 1, by: 1)
    for index in positions {
        try budget.spend()
        let model = try snapshot.declaration(ids[index])
        var duplicate = false
        for prior in ids.startIndex..<index {
            try budget.spend()
            if try snapshot.declaration(ids[prior]).name == model.name { duplicate = true; break }
        }
        if duplicate {
            guard result.profile == .pinnedNgspiceNormalV1 else { throw .invalidResolvedInstance }
            continue
        }
        guard model.invalidCoefficient == nil, visit < result.candidates.count else { throw .invalidResolvedInstance }
        let evidence = result.candidates[visit]; visit += 1
        guard evidence.declaration == model.id else { throw .invalidResolvedInstance }
        let candidateRelease = try MOSSelectionPolicy.release(model, profile: result.profile).0
        let candidateSchema = MOSModelSchema(release: candidateRelease)
        for (assignmentIndex, assignment) in model.coefficients.enumerated() {
            for _ in (try snapshot.name(of: assignment.symbol)).utf8 { try budget.spend() }
            let definition = try MOSSelectionPolicy.parameter(assignment.symbol, role: .model,
                schema: candidateSchema, snapshot: snapshot)
            if result.profile == .coreStrictV1 {
                for prior in model.coefficients[..<assignmentIndex] {
                    try budget.spend()
                    let earlier = try MOSSelectionPolicy.parameter(prior.symbol, role: .model,
                        schema: candidateSchema, snapshot: snapshot)
                    guard definition.canonicalName != earlier.canonicalName else { throw .invalidResolvedInstance }
                }
            }
        }
        var expected: MOSCandidateDisposition = .selected
        if family {
            guard let bounds = evidence.bounds else { throw .invalidResolvedInstance }
            let match = try MOSSelectionPolicy.matches(bounds, geometry: result.selectionGeometry,
                profile: result.profile, declaration: model.id)
            expected = match ? .selected : (bounds.missingMask != 0 ? .missingBounds : .outsideBounds)
        } else { guard evidence.bounds == nil else { throw .invalidResolvedInstance } }
        guard expected == evidence.disposition else { throw .invalidResolvedInstance }
        if expected == .selected {
            selectedCount += 1
            guard model.id == result.declaration else { throw .invalidResolvedInstance }
            if let bounds = evidence.bounds {
                guard bounds == (try MOSSelectionPolicy.bounds(result.modelCoefficients, snapshot: snapshot)) else { throw .invalidResolvedInstance }
            }
            if result.profile == .pinnedNgspiceNormalV1 || !family { break }
        }
    }
    guard selectedCount == 1, visit == result.candidates.count else { throw .invalidResolvedInstance }
    try budget.add(UInt64(MemoryLayout<MOSResolvedInspection>.stride))
    return MOSResolvedInspection(declaration: selected.id, name: selected.name,
        owningScope: selected.scope, release: result.release, candidates: result.candidates)
}

private func inspectParameters(_ values: [MOSNumericParameter], role: MOSParameterRole,
    schema: MOSModelSchema, snapshot: MOSDeclarationSnapshot, budget: inout MOSStorageBudget)
    throws(MOSResolutionFailure) {
    for (index, parameter) in values.enumerated() {
        try budget.spend()
        for _ in (try snapshot.name(of: parameter.symbol)).utf8 { try budget.spend() }
        let definition = try MOSSelectionPolicy.parameter(parameter.symbol, role: role, schema: schema, snapshot: snapshot)
        try MOSSelectionPolicy.validate(parameter.value, definition: definition)
        for prior in values[..<index] {
            try budget.spend()
            let earlier = try MOSSelectionPolicy.parameter(prior.symbol, role: role, schema: schema, snapshot: snapshot)
            guard earlier.canonicalName != definition.canonicalName else { throw .invalidResolvedInstance }
        }
    }
}
