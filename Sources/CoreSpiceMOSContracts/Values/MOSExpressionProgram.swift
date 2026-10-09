public struct MOSExpressionProgram: Sendable, Hashable {
    public let id: MOSProgramID
    public let expression: MOSExpression
    public let nodeCount: Int
    public let maximumDepth: Int
    public let dependencies: [MOSSymbolID]
    public let referencedFunctions: [MOSSymbolID]
    /// Conservative retained AST payload plus actual metadata buffer element capacities.
    public let retainedBytes: UInt64
    /// Includes simultaneous old/new capacities during scratch growth; excludes allocator metadata.
    public let peakOwnedBufferBytes: UInt64
    public let workUnits: UInt64

    public init(id: MOSProgramID, expression: MOSExpression, limits: MOSResolutionLimits,
                control: (any MOSResolutionControlling)? = nil) throws(MOSResolutionFailure) {
        var workUsed: UInt64 = 0
        try self.init(id: id, expression: expression, limits: limits,
            availableBytes: limits.maximumRetainedBytes, workUsed: &workUsed, control: control)
    }
    package init(id: MOSProgramID, expression: MOSExpression, limits: MOSResolutionLimits,
                 availableBytes: UInt64, workUsed: inout UInt64,
                 control: (any MOSResolutionControlling)?) throws(MOSResolutionFailure) {
        var budget = MOSStorageBudget(maximumBytes: availableBytes,
            maximumSteps: limits.maximumEvaluationSteps - workUsed, control: control)
        defer { workUsed += budget.steps }
        try budget.add(UInt64(MemoryLayout<Self>.stride))
        var pending: [(MOSExpression, Int)] = []
        try budget.reserve(&pending, required: 1)
        pending.append((expression, 1))
        var count = 0
        var depth = 0
        var dependencies: [MOSSymbolID] = []
        var functions: [MOSSymbolID] = []
        while let (node, currentDepth) = pending.popLast() {
            try budget.spend()
            guard count < limits.maximumExpressionNodes else { throw .limitExceeded(.expressionNodes) }
            guard currentDepth <= limits.maximumExpressionDepth else { throw .limitExceeded(.expressionDepth) }
            try budget.add(UInt64(MemoryLayout<MOSExpression>.stride))
            count += 1; depth = max(depth, currentDepth)
            func append(_ child: MOSExpression) throws(MOSResolutionFailure) {
                try budget.spend()
                guard pending.count < limits.maximumExpressionNodes - count else {
                    throw .limitExceeded(.expressionNodes)
                }
                try budget.reserve(&pending, required: pending.count + 1)
                pending.append((child, currentDepth + 1))
            }
            switch node {
            case .literal(let value):
                guard value.isFinite else { throw .invalidRequest }
            case .reference(let symbol):
                try budget.reserve(&dependencies, required: dependencies.count + 1)
                dependencies.append(symbol)
            case .unary(_, let child): try append(child)
            case .binary(_, let lhs, let rhs): try append(rhs); try append(lhs)
            case .function(let name, let arguments):
                try budget.addArray(arguments)
                try budget.reserve(&functions, required: functions.count + 1)
                functions.append(name)
                for argument in arguments.reversed() { try append(argument) }
            case .conditional(let condition, let yes, let no): try append(no); try append(yes); try append(condition)
            }
        }
        // Heap sort uses the admitted array capacity without auxiliary sorting storage.
        func sortUnique(_ values: inout [MOSSymbolID]) throws(MOSResolutionFailure) {
            guard values.count > 1 else { return }
            func sift(_ start: Int, end: Int) throws(MOSResolutionFailure) {
                var root = start
                while root < end / 2 {
                    try budget.spend()
                    var child = root * 2 + 1
                    if child + 1 < end, values[child].rawValue < values[child + 1].rawValue { child += 1 }
                    guard values[root].rawValue < values[child].rawValue else { return }
                    values.swapAt(root, child); root = child
                }
            }
            for start in (0..<(values.count / 2)).reversed() { try sift(start, end: values.count) }
            for end in (1..<values.count).reversed() {
                try budget.spend(); values.swapAt(0, end); try sift(0, end: end)
            }
            var write = 1
            for read in 1..<values.count {
                try budget.spend()
                if values[read] != values[write - 1] { values[write] = values[read]; write += 1 }
            }
            values.removeLast(values.count - write)
        }
        try sortUnique(&dependencies); try sortUnique(&functions)
        let peak = budget.peakBytes
        budget.release(try MOSStorageBudget.capacityBytes(pending.capacity, of: (MOSExpression, Int).self))
        self.id = id; self.expression = expression; self.nodeCount = count; self.maximumDepth = depth
        self.dependencies = dependencies; self.referencedFunctions = functions
        self.retainedBytes = budget.bytes; self.peakOwnedBufferBytes = peak; self.workUnits = budget.steps
    }
}
