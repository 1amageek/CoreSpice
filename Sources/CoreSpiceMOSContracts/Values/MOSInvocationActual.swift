/// One explicit invocation argument occurrence, including symbols absent from defaults.
public struct MOSInvocationActual: Sendable, Hashable {
    public let symbol: MOSSymbolID
    public let value: MOSInvocationValue
    public let source: MOSSourceOccurrence?
    public let retainedBytes: UInt64
    public var program: MOSProgramID? {
        if case .program(let program) = value { return program }
        return nil
    }

    public init(symbol: MOSSymbolID, program: MOSProgramID, source: MOSSourceOccurrence? = nil,
                limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        try self.init(symbol: symbol, value: .program(program), source: source, limits: limits)
    }

    public init(symbol: MOSSymbolID, constant: Double, source: MOSSourceOccurrence? = nil,
                limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        guard constant.isFinite else { throw .nonFiniteValue(symbol) }
        try self.init(symbol: symbol, value: .constant(constant), source: source, limits: limits)
    }

    private init(symbol: MOSSymbolID, value: MOSInvocationValue, source: MOSSourceOccurrence?,
                 limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps)
        try budget.add(UInt64(MemoryLayout<Self>.stride)); try budget.addSource(source)
        self.symbol = symbol; self.value = value; self.source = source; self.retainedBytes = budget.bytes
    }
}
