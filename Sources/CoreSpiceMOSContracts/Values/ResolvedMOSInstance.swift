/// Immutable resolution only; inspection capability does not admit numerical execution.
public struct ResolvedMOSInstance: Sendable, Hashable {
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
    public let rules: [MOSResolutionRule]
    public let candidates: [MOSCandidateEvidence]
    public let retainedBytes: UInt64

    package init(source: MOSSourceOccurrence, instanceSource: MOSSourceOccurrence?, selectedName: MOSSymbolID,
                 symbolNames: [String], scope: MOSScopeID, scopeInstantiation: UInt64, instance: String, declaration: MOSDeclarationID, polarity: MOSPolarity,
                 release: MOSModelRelease, releaseOrigin: MOSReleaseOrigin, schema: MOSSchemaIdentity,
                 modelCoefficients: [MOSNumericParameter], instanceParameters: [MOSNumericParameter],
                 rawGeometry: MOSInputGeometry, normalizedGeometry: MOSNormalizedGeometry,
                 selectionGeometry: MOSSelectionGeometry, profile: MOSInputProfile,
                 rules: [MOSResolutionRule], candidates: [MOSCandidateEvidence],
                 limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps)
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        try budget.addSource(source); try budget.addSource(instanceSource); try budget.addText(instance)
        try budget.addArray(symbolNames)
        for name in symbolNames { try budget.spend(); try budget.addText(name) }
        try budget.addArray(modelCoefficients); try budget.addArray(instanceParameters)
        try budget.addArray(rules); try budget.addArray(candidates)
        if case .explicit(let version) = releaseOrigin { try budget.addText(version) }
        var selectedCount = 0
        var selectedMatches = false
        for candidate in candidates {
            try budget.spend()
            if candidate.disposition == .selected {
                selectedCount += 1
                if candidate.declaration == declaration { selectedMatches = true }
            }
        }
        guard !instance.isEmpty, Int(selectedName.rawValue) < symbolNames.count, schema == release.schemaIdentity,
              selectedCount == 1, selectedMatches,
              selectionGeometry.fingerDivisor.isFinite, selectionGeometry.fingerDivisor > 0 else {
            throw .invalidResolvedInstance
        }
        if case .explicit(let exact) = releaseOrigin, release.exactVersion != exact {
            throw .invalidResolvedInstance
        }
        try rawGeometry.validate(); try normalizedGeometry.validate()
        try MOSNormalizedGeometry(length: selectionGeometry.length, width: selectionGeometry.width).validate()
        var seen = Set<MOSSymbolID>()
        try budget.reserveSet(&seen, required: max(modelCoefficients.count, instanceParameters.count))
        func validate(_ parameters: [MOSNumericParameter]) throws(MOSResolutionFailure) {
            seen.removeAll(keepingCapacity: true)
            for parameter in parameters {
                try budget.spend()
                guard Int(parameter.symbol.rawValue) < symbolNames.count else { throw .invalidResolvedInstance }
                guard parameter.value.isFinite else { throw .nonFiniteValue(parameter.symbol) }
                guard seen.insert(parameter.symbol).inserted else { throw .duplicateParameter(parameter.symbol) }
            }
        }
        try validate(modelCoefficients); try validate(instanceParameters)
        budget.release(try MOSStorageBudget.capacityBytes(seen.capacity, of: MOSSymbolID.self))
        self.retainedBytes = budget.bytes
        self.source = source; self.instanceSource = instanceSource; self.selectedName = selectedName
        self.symbolNames = symbolNames; self.scope = scope; self.scopeInstantiation = scopeInstantiation
        self.instance = instance; self.declaration = declaration; self.polarity = polarity
        self.release = release; self.releaseOrigin = releaseOrigin; self.schema = schema
        self.modelCoefficients = modelCoefficients; self.instanceParameters = instanceParameters
        self.rawGeometry = rawGeometry; self.normalizedGeometry = normalizedGeometry
        self.selectionGeometry = selectionGeometry; self.profile = profile; self.rules = rules; self.candidates = candidates
    }
}
