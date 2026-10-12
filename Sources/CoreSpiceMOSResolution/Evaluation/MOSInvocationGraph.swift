import CoreSpiceMOSContracts

/// Checked concrete environments sharing one immutable declaration snapshot.
public final class MOSInvocationGraph: Sendable {
    public let snapshot: MOSDeclarationSnapshot
    public let invocations: [MOSScopeInvocation]
    public let finalBindings: [MOSInvocationBinding]
    public let retainedBytes: UInt64
    public let peakOwnedBufferBytes: UInt64
    public let workUnits: UInt64
    public let maximumDepth: Int
    private let invocationIndex: [UInt64: Int]
    private let bindingIndex: [MOSInvocationBindingKey: Int]

    public init(snapshot: MOSDeclarationSnapshot, invocations: [MOSScopeInvocation],
                limits: MOSResolutionLimits, control: (any MOSResolutionControlling)? = nil)
        throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps, control: control)
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        try budget.add(snapshot.retainedBytes)
        try budget.addArray(invocations)
        guard invocations.count <= limits.maximumInvocations else { throw .limitExceeded(.invocations) }
        var indices: [UInt64: Int] = [:]
        var winners: [MOSInvocationBindingKey: Int] = [:]
        var bindings: [MOSInvocationBinding] = []
        var depth = 0

        for (position, invocation) in invocations.enumerated() {
            try budget.spend()
            guard indices[invocation.id] == nil else { throw .duplicateInvocation(invocation.id) }
            let scope = try snapshot.scope(invocation.scope)
            try budget.addSource(invocation.source)
            try budget.addArray(invocation.actuals)
            for actual in invocation.actuals {
                try budget.spend(); try budget.addSource(actual.source)
                if try snapshot.name(of: actual.symbol) == "temper" { throw .reservedParameter(actual.symbol) }
                switch actual.value {
                case .program(let program): _ = try snapshot.program(program)
                case .constant(let value): guard value.isFinite else { throw .nonFiniteValue(actual.symbol) }
                }
            }

            var currentDepth = 1
            if let caller = invocation.callerInvocationID {
                guard scope.parent != nil, indices[caller] != nil else { throw .invalidInvocation(invocation.id) }
                var ancestor: UInt64? = caller
                var foundLexicalParent = false
                while let id = ancestor {
                    try budget.spend()
                    guard currentDepth < limits.maximumScopeDepth,
                          let parentIndex = indices[id] else { throw .limitExceeded(.scopeDepth) }
                    currentDepth += 1
                    let parent = invocations[parentIndex]
                    if parent.scope == scope.parent { foundLexicalParent = true }
                    ancestor = parent.callerInvocationID
                }
                guard foundLexicalParent else { throw .invalidInvocation(invocation.id) }
            } else {
                guard scope.parent == nil else { throw .invalidInvocation(invocation.id) }
            }
            depth = max(depth, currentDepth)
            if indices.count == indices.capacity { try budget.reserveDictionary(&indices, required: indices.count + 1) }
            indices[invocation.id] = position

            func install(symbol: MOSSymbolID, value: MOSInvocationValue, binding: MOSBindingID?,
                         source: MOSSourceOccurrence?, caller: UInt64?) throws(MOSResolutionFailure) {
                try budget.spend()
                let key = MOSInvocationBindingKey(invocation: invocation.id, symbol: symbol)
                let beforeSource = budget.bytes
                try budget.addSource(source)
                let sourceBytes = budget.bytes - beforeSource
                let winner = MOSInvocationBinding(ownerInvocation: invocation.id, symbol: symbol,
                    value: value, sourceBindingID: binding, source: source,
                    selfReferenceCallerInvocationID: caller, sourceRetainedBytes: sourceBytes)
                if let index = winners[key] {
                    budget.release(bindings[index].sourceRetainedBytes)
                    bindings[index] = winner
                } else {
                    guard bindings.count < limits.maximumInvocationBindings else { throw .limitExceeded(.invocationBindings) }
                    if bindings.count == bindings.capacity { try budget.reserve(&bindings, required: bindings.count + 1) }
                    if winners.count == winners.capacity { try budget.reserveDictionary(&winners, required: winners.count + 1) }
                    winners[key] = bindings.count
                    bindings.append(winner)
                }
            }

            for id in scope.parameterBindings {
                try budget.spend()
                let binding = try snapshot.binding(id)
                try install(symbol: binding.symbol, value: .program(binding.program), binding: id,
                    source: binding.source, caller: nil)
            }
            // Actual occurrences are retained in order; a temporary set rejects duplicate names.
            var actualSymbols: Set<MOSSymbolID> = []
            try budget.reserveSet(&actualSymbols, required: invocation.actuals.count)
            for actual in invocation.actuals {
                try budget.spend()
                guard actualSymbols.insert(actual.symbol).inserted else { throw .duplicateParameter(actual.symbol) }
                try install(symbol: actual.symbol, value: actual.value, binding: nil,
                    source: actual.source, caller: actual.program == nil ? nil : invocation.callerInvocationID)
            }
            budget.release(try MOSStorageBudget.capacityBytes(actualSymbols.capacity, of: MOSSymbolID.self))
        }
        self.snapshot = snapshot; self.invocations = invocations; self.finalBindings = bindings
        self.invocationIndex = indices; self.bindingIndex = winners
        self.retainedBytes = budget.bytes; self.peakOwnedBufferBytes = budget.peakBytes
        self.workUnits = budget.steps; self.maximumDepth = depth
    }

    public func sameStorage(as other: MOSInvocationGraph) -> Bool { self === other }

    public func invocation(_ id: UInt64) throws(MOSResolutionFailure) -> MOSScopeInvocation {
        guard let index = invocationIndex[id] else { throw .invalidInvocation(id) }
        return invocations[index]
    }

    public func localBinding(_ symbol: MOSSymbolID, in invocation: UInt64)
        throws(MOSResolutionFailure) -> MOSInvocationBinding? {
        _ = try self.invocation(invocation)
        _ = try snapshot.name(of: symbol)
        return bindingIndex[MOSInvocationBindingKey(invocation: invocation, symbol: symbol)].map { finalBindings[$0] }
    }

    /// Lookup is bounded by the graph's admitted caller depth.
    public func numericBinding(_ symbol: MOSSymbolID, in invocation: UInt64)
        throws(MOSResolutionFailure) -> MOSInvocationBinding? {
        _ = try snapshot.name(of: symbol)
        var current: UInt64? = invocation
        while let id = current {
            let entry = try self.invocation(id)
            if let index = bindingIndex[MOSInvocationBindingKey(invocation: id, symbol: symbol)] {
                return finalBindings[index]
            }
            current = entry.callerInvocationID
        }
        return nil
    }

    /// The caller chain supplies identity, not permission to expose nonlexical names.
    public func lexicalOwner(of scope: MOSScopeID, from invocation: UInt64)
        throws(MOSResolutionFailure) -> UInt64 {
        _ = try snapshot.scope(scope)
        var lexical: MOSScopeID? = try self.invocation(invocation).scope
        while let id = lexical, id != scope { lexical = try snapshot.scope(id).parent }
        guard lexical != nil else { throw .invalidScope }
        var current: UInt64? = invocation
        while let id = current {
            let entry = try self.invocation(id)
            if entry.scope == scope { return id }
            current = entry.callerInvocationID
        }
        throw .invalidInvocation(invocation)
    }
}
