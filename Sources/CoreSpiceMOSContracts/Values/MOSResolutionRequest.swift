public struct MOSResolutionRequest: Sendable, Hashable {
    public let source: MOSSourceOccurrence?
    public let instance: String
    public let scope: MOSScopeID
    public let scopeInstantiation: UInt64
    public let modelReference: MOSSymbolID
    public let profile: MOSInputProfile
    /// Supplied instance parameters remain expression programs, including omitted-value absence.
    public let bindings: [MOSExpressionBinding]
    public let geometryScale: Double
    public let seed: UInt64
    public let globalWidthPerFinger: Bool
    public let retainedBytes: UInt64
    public init(source: MOSSourceOccurrence? = nil, instance: String, scope: MOSScopeID, scopeInstantiation: UInt64,
                modelReference: MOSSymbolID, profile: MOSInputProfile,
                bindings: [MOSExpressionBinding],
                geometryScale: Double, seed: UInt64, globalWidthPerFinger: Bool = false,
                limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        guard !instance.isEmpty, geometryScale.isFinite, geometryScale > 0 else { throw .invalidRequest }
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps)
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        try budget.addSource(source); try budget.addText(instance)
        try budget.addArray(bindings)
        var symbols = Set<MOSSymbolID>()
        try budget.reserveSet(&symbols, required: bindings.count)
        for value in bindings {
            try budget.spend()
            guard symbols.insert(value.symbol).inserted else { throw .duplicateParameter(value.symbol) }
        }
        budget.release(try MOSStorageBudget.capacityBytes(symbols.capacity, of: MOSSymbolID.self))
        self.retainedBytes = budget.bytes
        self.source = source
        self.instance = instance; self.scope = scope; self.scopeInstantiation = scopeInstantiation
        self.modelReference = modelReference; self.profile = profile; self.bindings = bindings
        self.geometryScale = geometryScale; self.seed = seed
        self.globalWidthPerFinger = globalWidthPerFinger
    }

    /// Storage admission metadata does not participate in semantic request identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.instance == rhs.instance && lhs.scope == rhs.scope &&
        lhs.scopeInstantiation == rhs.scopeInstantiation && lhs.modelReference == rhs.modelReference &&
        lhs.profile == rhs.profile && lhs.bindings == rhs.bindings && lhs.geometryScale == rhs.geometryScale &&
        lhs.seed == rhs.seed && lhs.globalWidthPerFinger == rhs.globalWidthPerFinger
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source); hasher.combine(instance); hasher.combine(scope)
        hasher.combine(scopeInstantiation); hasher.combine(modelReference); hasher.combine(profile)
        hasher.combine(bindings); hasher.combine(geometryScale); hasher.combine(seed)
        hasher.combine(globalWidthPerFinger)
    }

}
