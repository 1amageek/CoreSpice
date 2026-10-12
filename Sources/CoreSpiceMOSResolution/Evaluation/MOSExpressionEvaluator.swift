import CoreSpiceMOSContracts

/// Resolves a final numeric binding once per owning concrete invocation.
public func evaluateMOSBinding(_ symbol: MOSSymbolID, invocation: UInt64,
                               from snapshot: MOSDeclarationSnapshot, session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) -> Double {
    try session.checkHealthy()
    do throws(MOSResolutionFailure) {
        guard snapshot.sameStorage(as: session.snapshot) else { throw MOSResolutionFailure.conditionMismatch }
        let scope = try session.graph.invocation(invocation).scope
        session.recordExpression(binding: symbol, program: nil, invocation: invocation, scope: scope)
        try session.recordRootVisit(.binding(symbol, invocation: invocation))
        _ = try snapshot.name(of: symbol)
        return try runMOSExpression(.reference(symbol), invocation: invocation, lexicalScope: scope, session: &session)
    } catch { session.poison(error); throw error }
}

/// Evaluates this semantic expression slot; program identity alone never memoizes a random draw.
public func evaluateMOSProgram(_ program: MOSProgramID, invocation: UInt64, lexicalScope: MOSScopeID,
                               from snapshot: MOSDeclarationSnapshot, session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) -> Double {
    try session.checkHealthy()
    do throws(MOSResolutionFailure) {
        session.recordExpression(binding: nil, program: program, invocation: invocation, scope: lexicalScope)
        try session.recordRootVisit(.program(program, invocation: invocation, lexicalScope: lexicalScope))
        guard snapshot.sameStorage(as: session.snapshot) else { throw MOSResolutionFailure.conditionMismatch }
        _ = try session.lexicalOwner(of: lexicalScope, from: invocation)
        let compiled = try snapshot.program(program)
        guard compiled.nodeCount <= session.limits.maximumExpressionNodes else { throw MOSResolutionFailure.limitExceeded(.expressionNodes) }
        let expression = compiled.expression
        return try runMOSExpression(expression, invocation: invocation, lexicalScope: lexicalScope, session: &session)
    } catch { session.poison(error); throw error }
}

/// All recursion is represented by admitted buffers rather than the Swift call stack.
private func runMOSExpression(_ expression: MOSExpression, invocation: UInt64, lexicalScope: MOSScopeID,
                              session: inout MOSEvaluationSession) throws(MOSResolutionFailure) -> Double {
    var frames: [MOSEvaluationFrame] = []
    var values: [Double] = []
    var formals: [MOSNumericParameter] = []
    var activeBindings: [MOSInvocationBindingKey] = []
    var activeFunctions: [MOSFunctionID] = []
    defer {
        session.releaseEvaluationStorage(for: frames); session.releaseEvaluationStorage(for: values)
        session.releaseEvaluationStorage(for: formals); session.releaseEvaluationStorage(for: activeBindings)
        session.releaseEvaluationStorage(for: activeFunctions)
    }
    let initial = MOSEvaluationContext(invocation: invocation, lexicalScope: lexicalScope,
        formals: 0..<0, functionDepth: 0, selfSymbol: nil, selfCaller: nil)
    try push(.expression(expression, initial, depth: 1), onto: &frames, session: &session)
    while let frame = frames.popLast() {
        try session.spend(.evaluationSteps)
        switch frame {
        case .expression(let expression, let context, let depth):
            guard depth <= session.limits.maximumExpressionDepth else { throw .limitExceeded(.expressionDepth) }
            switch expression {
            case .literal(let value): try pushValue(value, onto: &values, session: &session)
            case .reference(let symbol):
                var formalValue: Double?
                for index in context.formals {
                    try session.spend(.evaluationSteps)
                    if formals[index].symbol == symbol { formalValue = formals[index].value; break }
                }
                if let formalValue { try pushValue(formalValue, onto: &values, session: &session); continue }
                let name = try session.snapshot.name(of: symbol)
                if name == "temper" {
                    do { try pushValue(session.scalarAmbient(), onto: &values, session: &session) }
                    catch { session.recordConditionPath(activeBindings); throw error }
                    continue
                }
                let lookupInvocation = symbol == context.selfSymbol ? (context.selfCaller ?? context.invocation) : context.invocation
                // Charge every bounded ancestry hop, including lookup work on a cache hit.
                var current: UInt64? = lookupInvocation
                var binding: MOSInvocationBinding?
                while let id = current {
                    try session.spend(.evaluationSteps)
                    if let local = try session.graph.localBinding(symbol, in: id) { binding = local; break }
                    current = try session.graph.invocation(id).callerInvocationID
                }
                guard let binding else {
                    if name == "time" || name == "hertz" { throw .unsupportedScalarVariable(symbol) }
                    throw .undefinedParameter(symbol)
                }
                let key = MOSInvocationBindingKey(invocation: binding.ownerInvocation, symbol: symbol)
                if let cached = session.cachedBinding(key) { try pushValue(cached, onto: &values, session: &session); continue }
                for active in activeBindings {
                    try session.spend(.evaluationSteps)
                    guard active != key else { throw .circularInvocationBinding(invocation: key.invocation, symbol: symbol) }
                }
                try session.reserve(&activeBindings, required: activeBindings.count + 1)
                activeBindings.append(key)
                let ownerScope = try session.graph.invocation(binding.ownerInvocation).scope
                let bindingContext = MOSEvaluationContext(invocation: binding.ownerInvocation, lexicalScope: ownerScope,
                    formals: 0..<0, functionDepth: context.functionDepth, selfSymbol: binding.symbol,
                    selfCaller: binding.selfReferenceCallerInvocationID)
                try push(.bindingEnd(key), onto: &frames, session: &session)
                let bindingExpression: MOSExpression
                switch binding.value {
                case .program(let program):
                    let compiled = try session.snapshot.program(program)
                    guard compiled.nodeCount <= session.limits.maximumExpressionNodes else { throw .limitExceeded(.expressionNodes) }
                    bindingExpression = compiled.expression
                case .constant(let value): bindingExpression = .literal(value)
                }
                try push(.expression(bindingExpression, bindingContext, depth: 1), onto: &frames, session: &session)
            case .unary(let op, let child):
                try push(.unary(op), onto: &frames, session: &session)
                try push(.expression(child, context, depth: depth + 1), onto: &frames, session: &session)
            case .binary(let op, let lhs, let rhs):
                try push(.binaryLeft(op, rhs, context, depth: depth), onto: &frames, session: &session)
                try push(.expression(lhs, context, depth: depth + 1), onto: &frames, session: &session)
            case .conditional(let condition, let yes, let no):
                try push(.conditional(yes, no, context, depth: depth), onto: &frames, session: &session)
                try push(.expression(condition, context, depth: depth + 1), onto: &frames, session: &session)
            case .function(let symbol, let arguments):
                _ = try session.snapshot.name(of: symbol)
                try push(.arguments(symbol, arguments, next: 0, base: values.count, context, depth: depth),
                    onto: &frames, session: &session)
            }
        case .unary(let op):
            let value = try popValue(&values)
            let result: Double
            switch op { case .plus: result = value; case .negate: result = -value; case .not: result = value == 0 ? 1 : 0 }
            try pushValue(result, onto: &values, session: &session)
        case .binaryLeft(let op, let rhs, let context, let depth):
            let lhs = try popValue(&values)
            if (op == .and && lhs == 0) || (op == .or && lhs != 0) {
                try pushValue(op == .and ? 0 : 1, onto: &values, session: &session)
            } else {
                try push(.binaryRight(op, lhs), onto: &frames, session: &session)
                try push(.expression(rhs, context, depth: depth + 1), onto: &frames, session: &session)
            }
        case .binaryRight(let op, let lhs):
            let rhs = try popValue(&values)
            try pushValue(try binaryMOSValue(op, lhs, rhs), onto: &values, session: &session)
        case .conditional(let yes, let no, let context, let depth):
            let condition = try popValue(&values)
            try push(.expression(condition != 0 ? yes : no, context, depth: depth + 1), onto: &frames, session: &session)
        case .arguments(let symbol, let arguments, let next, let base, let context, let depth):
            if next < arguments.count {
                try push(.arguments(symbol, arguments, next: next + 1, base: base, context, depth: depth),
                    onto: &frames, session: &session)
                try push(.expression(arguments[next], context, depth: depth + 1), onto: &frames, session: &session)
                continue
            }
            let name = try session.snapshot.name(of: symbol)
            if let builtin = try builtinMOSValue(name, symbol: symbol, arguments: values[base...], session: &session) {
                values.removeLast(values.count - base)
                try pushValue(builtin, onto: &values, session: &session)
                continue
            }
            var lexical: MOSScopeID? = context.lexicalScope
            var function: MOSFunctionDeclaration?
            while let scope = lexical {
                try session.spend(.evaluationSteps)
                let declaration = try session.snapshot.scope(scope)
                for id in declaration.functions.reversed() {
                    try session.spend(.evaluationSteps)
                    let candidate = try session.snapshot.function(id)
                    if candidate.symbol == symbol { function = candidate; break }
                }
                if function != nil { break }
                lexical = declaration.parent
            }
            guard let function else { throw .unsupportedFunction(symbol) }
            _ = try session.lexicalOwner(of: function.scope, from: context.invocation)
            guard arguments.count == function.parameters.count else { throw .invalidFunctionArity(symbol) }
            guard context.functionDepth < session.limits.maximumFunctionDepth else { throw .limitExceeded(.functionDepth) }
            for active in activeFunctions {
                try session.spend(.evaluationSteps)
                guard active != function.id else { throw .recursiveFunction(function.id) }
            }
            let formalsBase = formals.count
            try session.reserve(&formals, required: formals.count + arguments.count)
            for (offset, parameter) in function.parameters.enumerated() {
                try session.spend(.evaluationSteps)
                formals.append(MOSNumericParameter(symbol: parameter, value: values[base + offset]))
            }
            values.removeLast(values.count - base)
            try session.reserve(&activeFunctions, required: activeFunctions.count + 1)
            activeFunctions.append(function.id)
            let bodyContext = MOSEvaluationContext(invocation: context.invocation, lexicalScope: function.scope,
                formals: formalsBase..<formals.count, functionDepth: context.functionDepth + 1,
                selfSymbol: context.selfSymbol, selfCaller: context.selfCaller)
            try push(.functionEnd(function.id, formalsBase: formalsBase), onto: &frames, session: &session)
            let compiled = try session.snapshot.program(function.program)
            guard compiled.nodeCount <= session.limits.maximumExpressionNodes else { throw .limitExceeded(.expressionNodes) }
            try push(.expression(compiled.expression, bodyContext, depth: 1), onto: &frames, session: &session)
        case .bindingEnd(let key):
            guard activeBindings.popLast() == key, let result = values.last else { throw .invalidArithmetic }
            try session.storeBinding(result, for: key)
        case .functionEnd(let function, let base):
            guard activeFunctions.popLast() == function else { throw .invalidArithmetic }
            formals.removeLast(formals.count - base)
        }
    }
    guard values.count == 1, let result = values.last else { throw .invalidArithmetic }
    return result
}

private func push(_ frame: MOSEvaluationFrame, onto frames: inout [MOSEvaluationFrame],
                  session: inout MOSEvaluationSession) throws(MOSResolutionFailure) {
    try session.reserve(&frames, required: frames.count + 1); frames.append(frame)
}
private func pushValue(_ value: Double, onto values: inout [Double], session: inout MOSEvaluationSession)
    throws(MOSResolutionFailure) {
    guard value.isFinite else { throw .nonFiniteExpression }
    try session.reserve(&values, required: values.count + 1); values.append(value)
}
private func popValue(_ values: inout [Double]) throws(MOSResolutionFailure) -> Double {
    guard let value = values.popLast() else { throw .invalidArithmetic }; return value
}
package func binaryMOSValue(_ op: MOSBinaryOperator, _ lhs: Double, _ rhs: Double) throws(MOSResolutionFailure) -> Double {
    switch op {
    case .add: return lhs + rhs
    case .subtract: return lhs - rhs
    case .multiply: return lhs * rhs
    case .divide: guard rhs != 0 else { throw .invalidArithmetic }; return lhs / rhs
    case .modulo: guard rhs != 0 else { throw .invalidArithmetic }; return lhs.truncatingRemainder(dividingBy: rhs)
    case .power: return MOSMath.power(lhs, rhs)
    case .equal: return lhs == rhs ? 1 : 0
    case .notEqual: return lhs != rhs ? 1 : 0
    case .lessThan: return lhs < rhs ? 1 : 0
    case .lessOrEqual: return lhs <= rhs ? 1 : 0
    case .greaterThan: return lhs > rhs ? 1 : 0
    case .greaterOrEqual: return lhs >= rhs ? 1 : 0
    case .and: return lhs != 0 && rhs != 0 ? 1 : 0
    case .or: return lhs != 0 || rhs != 0 ? 1 : 0
    }
}
