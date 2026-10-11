/// Immutable resolution only; inspection capability does not admit numerical execution.
public struct ResolvedMOSInstance: Sendable, Hashable {
    public let identitySpace: MOSIdentitySpace
    public let source: MOSSourceOccurrence
    public let instanceSource: MOSSourceOccurrence?
    public let selectedName: MOSSymbolID
    public let symbolNames: [String]
    public let scope: MOSScopeID
    public let scopeInstantiation: UInt64
    public let instance: String
    public let declaration: MOSDeclarationID
    public let polarity: MOSPolarity
    public let release: MOSModelRelease
    public let releaseOrigin: MOSReleaseOrigin
    public let schema: MOSSchemaIdentity
    public let modelCoefficients: [MOSNumericParameter]
    public let instanceParameters: [MOSNumericParameter]
    public let rawGeometry: MOSInputGeometry
    public let normalizedGeometry: MOSNormalizedGeometry
    public let selectionGeometry: MOSSelectionGeometry
    public let profile: MOSInputProfile
    public let geometryScale: Double
    public let rules: [MOSResolutionRule]
    public let candidates: [MOSCandidateEvidence]
    public let retainedBytes: UInt64

    package init(identitySpace: MOSIdentitySpace, source: MOSSourceOccurrence, instanceSource: MOSSourceOccurrence?, selectedName: MOSSymbolID,
                 symbolNames: [String], scope: MOSScopeID, scopeInstantiation: UInt64, instance: String, declaration: MOSDeclarationID, polarity: MOSPolarity,
                 release: MOSModelRelease, releaseOrigin: MOSReleaseOrigin, schema: MOSSchemaIdentity,
                 modelCoefficients: [MOSNumericParameter], instanceParameters: [MOSNumericParameter],
                 rawGeometry: MOSInputGeometry, normalizedGeometry: MOSNormalizedGeometry,
                 selectionGeometry: MOSSelectionGeometry, profile: MOSInputProfile, geometryScale: Double,
                 rules: [MOSResolutionRule], candidates: [MOSCandidateEvidence],
                 limits: MOSResolutionLimits, workBudget: inout MOSStorageBudget) throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps)
        try workBudget.spend()
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        try budget.addSource(source, chargingWorkTo: &workBudget)
        try budget.addSource(instanceSource, chargingWorkTo: &workBudget)
        try budget.addText(instance, chargingWorkTo: &workBudget)
        try budget.addArray(symbolNames)
        for name in symbolNames { try workBudget.spend(); try budget.addText(name, chargingWorkTo: &workBudget) }
        try budget.addArray(modelCoefficients); try budget.addArray(instanceParameters)
        try budget.addArray(rules); try budget.addArray(candidates)
        if case .explicit(let version) = releaseOrigin { try budget.addText(version, chargingWorkTo: &workBudget) }
        var selectedCount = 0
        var selectedMatches = false
        for candidate in candidates {
            try workBudget.spend()
            if candidate.disposition == .selected {
                selectedCount += 1
                if candidate.declaration == declaration { selectedMatches = true }
            }
        }
        guard !instance.isEmpty, Int(selectedName.rawValue) < symbolNames.count, schema == release.schemaIdentity,
              selectedCount == 1, selectedMatches, geometryScale.isFinite, geometryScale > 0,
              selectionGeometry.fingerDivisor.isFinite, selectionGeometry.fingerDivisor > 0 else {
            throw .invalidResolvedInstance
        }
        if case .explicit(let exact) = releaseOrigin {
            do {
                guard try MOSModelRelease.resolve(level: release.level, version: exact, profile: profile) == release else {
                    throw MOSResolutionFailure.invalidResolvedInstance
                }
            } catch { throw .invalidResolvedInstance }
        }
        if case .explicitLevel(let level) = releaseOrigin,
           release.exactVersion != nil || release.level != level { throw .invalidResolvedInstance }
        if case .defaulted(let originProfile) = releaseOrigin {
            guard originProfile == profile,
                  release == .level1 || (profile == .pinnedNgspiceNormalV1 &&
                    (release == .bsim3_3_3_0 || release == .bsim4_4_8_3)) else {
                throw .invalidResolvedInstance
            }
        }
        try rawGeometry.validate(); try normalizedGeometry.validate()
        try MOSNormalizedGeometry(length: selectionGeometry.length, width: selectionGeometry.width).validate()
        var seen = Set<MOSSymbolID>()
        try workBudget.reserveSet(&seen, required: max(modelCoefficients.count, instanceParameters.count))
        let validationBytes = try MOSStorageBudget.capacityBytes(seen.capacity, of: MOSSymbolID.self)
        defer { workBudget.release(validationBytes) }
        func validate(_ parameters: [MOSNumericParameter]) throws(MOSResolutionFailure) {
            seen.removeAll(keepingCapacity: true)
            for parameter in parameters {
                try workBudget.spend()
                guard Int(parameter.symbol.rawValue) < symbolNames.count else { throw .invalidResolvedInstance }
                guard parameter.value.isFinite else { throw .nonFiniteValue(parameter.symbol) }
                guard seen.insert(parameter.symbol).inserted else { throw .duplicateParameter(parameter.symbol) }
            }
        }
        try validate(modelCoefficients); try validate(instanceParameters)
        self.retainedBytes = budget.bytes
        self.identitySpace = identitySpace
        self.source = source; self.instanceSource = instanceSource; self.selectedName = selectedName
        self.symbolNames = symbolNames; self.scope = scope; self.scopeInstantiation = scopeInstantiation
        self.instance = instance; self.declaration = declaration; self.polarity = polarity
        self.release = release; self.releaseOrigin = releaseOrigin; self.schema = schema
        self.modelCoefficients = modelCoefficients; self.instanceParameters = instanceParameters
        self.rawGeometry = rawGeometry; self.normalizedGeometry = normalizedGeometry
        self.selectionGeometry = selectionGeometry; self.profile = profile; self.geometryScale = geometryScale
        self.rules = rules; self.candidates = candidates
    }
}
