public struct MOSResolutionRequest: Sendable, Hashable {
    public let source: MOSSourceOccurrence?
    public let instance: String
    public let scope: MOSScopeID
    public let scopeInstantiation: UInt64
    public let modelReference: MOSSymbolID
    public let profile: MOSInputProfile
    /// Supplied instance parameters remain expression programs, including omitted-value absence.
    public let bindings: [MOSExpressionBinding]
    public let parameterOverrides: [MOSBindingOverride]
    public let geometryScale: Double
    public let seed: UInt64
    public let globalWidthPerFinger: Bool
    public let retainedBytes: UInt64
    public init(source: MOSSourceOccurrence? = nil, instance: String, scope: MOSScopeID, scopeInstantiation: UInt64,
                modelReference: MOSSymbolID, profile: MOSInputProfile,
                bindings: [MOSExpressionBinding], parameterOverrides: [MOSBindingOverride],
                geometryScale: Double, seed: UInt64, globalWidthPerFinger: Bool = false,
                limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        guard !instance.isEmpty, geometryScale.isFinite, geometryScale > 0 else { throw .invalidRequest }
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps)
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        try budget.addSource(source); try budget.addText(instance)
        try budget.addArray(bindings); try budget.addArray(parameterOverrides)
        var symbols = Set<MOSSymbolID>()
        try budget.reserveSet(&symbols, required: bindings.count)
        for value in bindings {
            try budget.spend()
            guard symbols.insert(value.symbol).inserted else { throw .duplicateParameter(value.symbol) }
        }
        var overrides = Set<MOSBindingID>()
        try budget.reserveSet(&overrides, required: parameterOverrides.count)
        for value in parameterOverrides {
            try budget.spend()
            guard overrides.insert(value.binding).inserted else { throw .invalidRequest }
        }
        budget.release(try MOSStorageBudget.capacityBytes(symbols.capacity, of: MOSSymbolID.self))
        budget.release(try MOSStorageBudget.capacityBytes(overrides.capacity, of: MOSBindingID.self))
        self.retainedBytes = budget.bytes
        self.source = source
        self.instance = instance; self.scope = scope; self.scopeInstantiation = scopeInstantiation
        self.modelReference = modelReference; self.profile = profile; self.bindings = bindings
        self.parameterOverrides = parameterOverrides; self.geometryScale = geometryScale; self.seed = seed
        self.globalWidthPerFinger = globalWidthPerFinger
    }
}
