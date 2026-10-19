import CoreSpiceIR
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Exclusive adapter ledger, shared only within one synchronous construction/session.
final class FrontendStorage {
    var budget: MOSStorageBudget
    let maximumExpressionDepth: Int
    let maximumFunctionDepth: Int
    init(limits: MOSResolutionLimits, control: (any MOSResolutionControlling)?) {
        maximumExpressionDepth = limits.maximumExpressionDepth
        maximumFunctionDepth = limits.maximumFunctionDepth
        budget = MOSStorageBudget(maximumBytes: limits.maximumRetainedBytes,
            maximumSteps: limits.maximumEvaluationSteps, control: control)
    }
    func spend() throws(MOSResolutionFailure) { try budget.spend() }
    func reserve<T>(_ values: inout [T], _ required: Int) throws(MOSResolutionFailure) {
        try budget.reserve(&values, required: required)
    }
    /// Only compileBody's unaliased local backing before its immutable scope publication.
    func reserveExclusiveComponents(_ values: inout [FrontendComponentTemplate], _ required: Int) throws(MOSResolutionFailure) {
        try budget.reserveExclusive(&values, required: required)
    }
    /// Only the noncopyable planner's private backing before consuming plan publication.
    func reserveExclusiveJobs(_ values: inout [FrontendExecutionJob], _ required: Int) throws(MOSResolutionFailure) {
        try budget.reserveExclusive(&values, required: required)
    }
    /// Only the noncopyable circuit builder's private backing before consuming publication.
    func reserveExclusiveInstances(_ values: inout [Instance], _ required: Int) throws(MOSResolutionFailure) {
        try budget.reserveExclusive(&values, required: required)
    }
    func reserve<K: Hashable, V>(_ values: inout [K: V], _ required: Int) throws(MOSResolutionFailure) {
        try budget.reserveDictionary(&values, required: required)
    }
    func text(_ value: String?) throws(MOSResolutionFailure) { try budget.addText(value) }
    func retain<T>(_ values: [T]) throws(MOSResolutionFailure) { try budget.addArray(values) }
    func entries<Key: Hashable & Comparable, Value>(_ dictionary: [Key: Value]) throws -> [(Key, Value)] {
        var result: [(Key, Value)] = []
        try reserve(&result, dictionary.count)
        for entry in dictionary { try spend(); result.append(entry) }
        func sift(_ start: Int, _ end: Int) throws {
            var root = start
            while root < end / 2 {
                try spend()
                var child = root * 2 + 1
                if child + 1 < end && result[child].0 < result[child + 1].0 { child += 1 }
                if result[root].0 >= result[child].0 { break }
                result.swapAt(root, child); root = child
            }
        }
        if result.count > 1 {
            for index in (0..<(result.count / 2)).reversed() { try sift(index, result.count) }
            for end in (1..<result.count).reversed() { result.swapAt(0, end); try sift(0, end) }
        }
        return result
    }
    func expression(_ expression: ParsedExpression, depth: Int = 1) throws {
        guard depth <= maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        try spend()
        try budget.add(UInt64(MemoryLayout<ParsedExpression>.stride))
        switch expression {
        case .literal: break
        case .identifier(let name): try text(name)
        case .unaryOperation(_, let value): try self.expression(value, depth: depth + 1)
        case .binaryOperation(_, let lhs, let rhs): try self.expression(lhs, depth: depth + 1); try self.expression(rhs, depth: depth + 1)
        case .conditional(let condition, let yes, let no):
            try self.expression(condition, depth: depth + 1); try self.expression(yes, depth: depth + 1); try self.expression(no, depth: depth + 1)
        case .functionCall(let name, let arguments):
            try text(name); try retain(arguments)
            for argument in arguments { try self.expression(argument, depth: depth + 1) }
        }
    }
    func value(_ value: ParsedParameterValue) throws {
        switch value {
        case .numeric, .boolean: break
        case .numericVector(let vector): try retain(vector)
        case .string(let text): try self.text(text)
        case .expression(let expression): try self.expression(expression)
        }
    }
}
