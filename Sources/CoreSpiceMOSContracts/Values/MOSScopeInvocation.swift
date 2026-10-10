/// An immutable concrete invocation; declaration occurrences remain in the snapshot.
public struct MOSScopeInvocation: Sendable, Hashable {
    public let id: UInt64
    public let scope: MOSScopeID
    public let callerInvocationID: UInt64?
    public let actuals: [MOSInvocationActual]
    public let source: MOSSourceOccurrence?
    public let retainedBytes: UInt64

    public init(id: UInt64, scope: MOSScopeID, callerInvocationID: UInt64?,
                actuals: [MOSInvocationActual], source: MOSSourceOccurrence? = nil,
                limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps)
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        try budget.addSource(source)
        guard actuals.count <= limits.maximumInvocationBindings else { throw .limitExceeded(.invocationBindings) }
        try budget.addArray(actuals)
        var seen: Set<MOSSymbolID> = []
        try budget.reserveSet(&seen, required: actuals.count)
        for actual in actuals {
            try budget.spend()
            try budget.addSource(actual.source)
            guard seen.insert(actual.symbol).inserted else { throw .duplicateParameter(actual.symbol) }
        }
        budget.release(try MOSStorageBudget.capacityBytes(seen.capacity, of: MOSSymbolID.self))
        self.id = id; self.scope = scope; self.callerInvocationID = callerInvocationID
        self.actuals = actuals; self.source = source; self.retainedBytes = budget.bytes
    }
}
