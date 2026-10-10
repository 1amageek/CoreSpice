import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

/// Converts parsed SPICE expressions into canonical simulation-time expressions.
struct BehavioralExpressionLowerer {
    struct Result {
        let expression: BehavioralExpression
        let referencedNodeNames: [String]
        let referencedBranchNames: [String]
    }

    private struct State {
        var depth = 0
        var dynamicBranchDepth = 0
        var dynamicConditionalDepth = 0
        var lexicalScope: MOSScopeID
        var referencedNodeNames: [String] = []
        var referencedNodeNameSet: Set<String> = []
        var referencedBranchNames: [String] = []
        var branchReferenceIndices: [String: Int] = [:]
        var evaluatingFunctions: Set<String> = []
    }

    private let parameters: [String: Double]
    private let compiled: CompiledNetlist
    private let lexicalScope: MOSScopeID
    private let portMapping: [String: String]
    private let prefix: String
    private let mapNodes: Bool

    init(parameters: [String: Double], compiled: CompiledNetlist, lexicalScope: MOSScopeID,
         prefix: String, portMapping: [String: String]) {
        self.parameters = parameters; self.compiled = compiled; self.lexicalScope = lexicalScope
        self.prefix = prefix; self.portMapping = portMapping; self.mapNodes = true
    }

    func lower(
        _ expression: ParsedExpression,
        into builder: inout BoundedFrontendNetlist, session: inout MOSEvaluationSession
    ) throws -> Result {
        var state = State(lexicalScope: lexicalScope)
        let lowered = try lower(
            expression,
            bindings: [:],
            state: &state,
            builder: &builder, session: &session
        )
        return Result(
            expression: lowered,
            referencedNodeNames: state.referencedNodeNames,
            referencedBranchNames: state.referencedBranchNames
        )
    }

    private func lower(
        _ expression: ParsedExpression,
        bindings: [String: BehavioralExpression],
        state: inout State,
        builder: inout BoundedFrontendNetlist, session: inout MOSEvaluationSession
    ) throws -> BehavioralExpression {
        guard state.depth < builder.storage.maximumExpressionDepth else { throw MOSResolutionFailure.limitExceeded(.expressionDepth) }
        state.depth += 1
        defer { state.depth -= 1 }
        try builder.storage.spend()
        try builder.storage.budget.add(UInt64(MemoryLayout<BehavioralExpression>.stride))
        switch expression {
        case .literal(let value):
            guard value.isFinite else {
                throw invalid(expression, "Behavioral literals must be finite")
            }
            return .constant(value)

        case .identifier(let name):
            if let boundExpression = bindings[name.lowercased()] {
                return boundExpression
            }
            if name.caseInsensitiveCompare("time") == .orderedSame {
                return .variable(.time)
            }
            if name.caseInsensitiveCompare("temper") == .orderedSame {
                return .variable(.ambientTemperatureCelsius)
            }
            if name.caseInsensitiveCompare("hertz") == .orderedSame {
                throw invalid(expression, "Runtime frequency variable 'hertz' is not supported")
            }
            if name.caseInsensitiveCompare("pi") == .orderedSame {
                return .constant(.pi)
            }
            guard let value = parameters[name.lowercased()], value.isFinite else {
                throw invalid(
                    expression,
                    "Identifier '\(name)' is neither a finite parameter nor a supported runtime variable"
                )
            }
            return .constant(value)

        case .unaryOperation(let operation, let operand):
            let mapped: BehavioralUnaryOperator = switch operation {
            case .negate: .negate
            case .not: .logicalNot
            case .plus: .plus
            }
            let value = try lower(operand, bindings: bindings, state: &state, builder: &builder, session: &session)
            if state.dynamicConditionalDepth == 0, case .constant(let number) = value {
                let folded: Double = switch operation { case .plus: number; case .negate: -number; case .not: number == 0 ? 1 : 0 }
                return .constant(folded)
            }
            return .unary(mapped, value)

        case .binaryOperation(let operation, let lhs, let rhs):
            let mapped: BehavioralBinaryOperator = switch operation {
            case .add: .add
            case .subtract: .subtract
            case .multiply: .multiply
            case .divide: .divide
            case .power: .power
            case .modulo: .modulo
            case .equal: .equal
            case .notEqual: .notEqual
            case .lessThan: .lessThan
            case .lessOrEqual: .lessOrEqual
            case .greaterThan: .greaterThan
            case .greaterOrEqual: .greaterOrEqual
            case .and: .logicalAnd
            case .or: .logicalOr
            }
            let left = try lower(lhs, bindings: bindings, state: &state, builder: &builder, session: &session)
            // Constant logical operands preserve the scalar interpreter's lazy branch rule.
            if case .constant(let number) = left {
                if operation == .and && number == 0 { return .constant(0) }
                if operation == .or && number != 0 { return .constant(1) }
            }
            let conditionalRight: Bool
            if operation == .and || operation == .or {
                if case .constant = left { conditionalRight = false } else { conditionalRight = true }
            } else { conditionalRight = false }
            if conditionalRight { state.dynamicBranchDepth += 1 }
            let right: BehavioralExpression
            do { right = try lower(rhs, bindings: bindings, state: &state, builder: &builder, session: &session) }
            catch { if conditionalRight { state.dynamicBranchDepth -= 1 }; throw error }
            if conditionalRight { state.dynamicBranchDepth -= 1 }
            if state.dynamicConditionalDepth == 0, case .constant(let lhs) = left, case .constant(let rhs) = right {
                let scalar: MOSBinaryOperator = switch operation {
                case .add: .add; case .subtract: .subtract; case .multiply: .multiply; case .divide: .divide
                case .power: .power; case .modulo: .modulo; case .equal: .equal; case .notEqual: .notEqual
                case .lessThan: .lessThan; case .lessOrEqual: .lessOrEqual; case .greaterThan: .greaterThan
                case .greaterOrEqual: .greaterOrEqual; case .and: .and; case .or: .or
                }
                let value = try binaryMOSValue(scalar, lhs, rhs)
                guard value.isFinite else { throw MOSResolutionFailure.nonFiniteExpression }
                return .constant(value)
            }
            return .binary(mapped, left, right)

        case .functionCall(let name, let arguments):
            return try lowerFunction(
                name: name,
                arguments: arguments,
                bindings: bindings,
                state: &state,
                builder: &builder, session: &session
            )

        case .conditional(let condition, let then, let `else`):
            let test = try lower(condition, bindings: bindings, state: &state, builder: &builder, session: &session)
            if case .constant(let number) = test {
                return try lower(number != 0 ? then : `else`, bindings: bindings, state: &state, builder: &builder, session: &session)
            }
            state.dynamicBranchDepth += 1
            state.dynamicConditionalDepth += 1
            defer { state.dynamicBranchDepth -= 1; state.dynamicConditionalDepth -= 1 }
            return .conditional(condition: test,
                then: try lower(then, bindings: bindings, state: &state, builder: &builder, session: &session),
                else: try lower(`else`, bindings: bindings, state: &state, builder: &builder, session: &session))
        }
    }

    private func lowerFunction(
        name: String,
        arguments: [ParsedExpression],
        bindings: [String: BehavioralExpression],
        state: inout State,
        builder: inout BoundedFrontendNetlist, session: inout MOSEvaluationSession
    ) throws -> BehavioralExpression {
        let loweredName = name.lowercased()
        if loweredName == "v" {
            guard arguments.count == 1 || arguments.count == 2 else {
                throw invalid(
                    .functionCall(name: name, arguments: arguments),
                    "V() requires one or two node names"
                )
            }
            let positiveName = try nodeName(from: arguments[0])
            let negativeName = arguments.count == 2
                ? try nodeName(from: arguments[1])
                : "0"
            let resolvedPositiveName = resolveNodeName(positiveName)
            let resolvedNegativeName = resolveNodeName(negativeName)
            try registerNode(resolvedPositiveName, state: &state, storage: builder.storage)
            try registerNode(resolvedNegativeName, state: &state, storage: builder.storage)
            return .variable(
                .nodeVoltage(
                    positive: try builder.node(resolvedPositiveName),
                    negative: try builder.node(resolvedNegativeName)
                )
            )
        }

        if loweredName == "i" {
            guard arguments.count == 1,
                  case .identifier(let sourceName) = arguments[0] else {
                throw invalid(
                    .functionCall(name: name, arguments: arguments),
                    "I() requires one voltage-source instance name"
                )
            }
            let resolvedName = prefix.isEmpty || sourceName.contains(".")
                ? sourceName
                : "\(prefix).\(sourceName)"
            let key = resolvedName.lowercased()
            let referenceIndex: Int
            if let existing = state.branchReferenceIndices[key] {
                referenceIndex = existing
            } else {
                referenceIndex = state.referencedBranchNames.count
                try builder.storage.reserve(&state.referencedBranchNames, referenceIndex + 1)
                try builder.storage.reserve(&state.branchReferenceIndices, state.branchReferenceIndices.count + 1)
                try builder.storage.text(resolvedName)
                state.referencedBranchNames.append(resolvedName)
                state.branchReferenceIndices[key] = referenceIndex
            }
            return .variable(.branchCurrentReference(referenceIndex))
        }

        if loweredName == "if" {
            guard arguments.count == 3 else {
                throw invalid(
                    .functionCall(name: name, arguments: arguments),
                    "if() requires three arguments"
                )
            }
            let test = try lower(arguments[0], bindings: bindings, state: &state, builder: &builder, session: &session)
            if case .constant(let number) = test {
                return try lower(arguments[number != 0 ? 1 : 2], bindings: bindings, state: &state, builder: &builder, session: &session)
            }
            state.dynamicBranchDepth += 1
            state.dynamicConditionalDepth += 1
            defer { state.dynamicBranchDepth -= 1; state.dynamicConditionalDepth -= 1 }
            return .conditional(condition: test,
                then: try lower(arguments[1], bindings: bindings, state: &state, builder: &builder, session: &session),
                else: try lower(arguments[2], bindings: bindings, state: &state, builder: &builder, session: &session))
        }

        if let (definition, declarationScope) = compiled.function(named: loweredName, scope: state.lexicalScope) {
            guard definition.parameters.count == arguments.count else {
                throw LoweringError.invalidComponent(
                    name: name,
                    reason: "Behavioral function requires \(definition.parameters.count) arguments"
                )
            }
            // Function formals belong only to this call; outer formals do not become free bindings.
            var functionBindings: [String: BehavioralExpression] = [:]
            for (parameter, argument) in zip(definition.parameters, arguments) {
                try builder.storage.reserve(&functionBindings, functionBindings.count + 1)
                functionBindings[parameter.lowercased()] = try lower(
                    argument,
                    bindings: bindings,
                    state: &state,
                    builder: &builder, session: &session
                )
            }
            guard state.evaluatingFunctions.count < builder.storage.maximumFunctionDepth else { throw MOSResolutionFailure.limitExceeded(.functionDepth) }
            try builder.storage.budget.reserveSet(&state.evaluatingFunctions, required: state.evaluatingFunctions.count + 1)
            let functionKey = String(declarationScope.rawValue) + ":" + loweredName
            try builder.storage.text(functionKey)
            guard state.evaluatingFunctions.insert(functionKey).inserted else {
                throw invalid(
                    .functionCall(name: name, arguments: arguments),
                    "Recursive behavioral function evaluation is not supported"
                )
            }
            defer { state.evaluatingFunctions.remove(functionKey) }

            let previousScope = state.lexicalScope
            state.lexicalScope = declarationScope
            defer { state.lexicalScope = previousScope }
            return try lower(
                definition.body,
                bindings: functionBindings,
                state: &state,
                builder: &builder, session: &session
            )
        }

        if ["rand", "random", "gauss", "agauss"].contains(loweredName) {
            guard state.dynamicBranchDepth == 0 else {
                throw invalid(.functionCall(name: name, arguments: arguments), "Random scalar capture in a dynamic branch is unsupported")
            }
            guard let symbol = compiled.snapshot.symbol(named: loweredName) else { throw MOSResolutionFailure.invalidRequest }
            var numbers: [Double] = []
            try builder.storage.reserve(&numbers, arguments.count)
            for argument in arguments {
                let value = try lower(argument, bindings: bindings, state: &state, builder: &builder, session: &session)
                guard case .constant(let number) = value else { throw invalid(argument, "Random scalar arguments must be static") }
                numbers.append(number)
            }
            guard let value = try builtinMOSValue(loweredName, symbol: symbol, arguments: numbers[...], session: &session) else {
                throw MOSResolutionFailure.invalidRequest
            }
            return .constant(value)
        }

        try builder.storage.budget.checkAdding(MOSStorageBudget.capacityBytes(arguments.count, of: BehavioralExpression.self))
        guard let function = behavioralFunction(named: loweredName) else {
            throw invalid(
                .functionCall(name: name, arguments: arguments),
                "Behavioral function '\(name)' is not supported"
            )
        }
        try validateArgumentCount(
            for: function,
            name: name,
            count: arguments.count
        )
        var loweredArguments: [BehavioralExpression] = []
        try builder.storage.reserve(&loweredArguments, arguments.count)
        for argument in arguments {
            loweredArguments.append(try lower(argument, bindings: bindings, state: &state, builder: &builder, session: &session))
        }
        guard state.dynamicConditionalDepth == 0 else { return .function(function, loweredArguments) }
        var numbers: [Double] = []
        try builder.storage.reserve(&numbers, loweredArguments.count)
        for argument in loweredArguments {
            guard case .constant(let number) = argument else { return .function(function, loweredArguments) }
            numbers.append(number)
        }
        guard let symbol = compiled.snapshot.symbol(named: loweredName),
              let value = try builtinMOSValue(loweredName, symbol: symbol, arguments: numbers[...], session: &session) else {
            throw MOSResolutionFailure.invalidRequest
        }
        return .constant(value)
    }

    private func behavioralFunction(named name: String) -> BehavioralFunction? {
        switch name {
        case "sin": .sine
        case "cos": .cosine
        case "tan": .tangent
        case "asin": .arcSine
        case "acos": .arcCosine
        case "atan": .arcTangent
        case "atan2": .arcTangent2
        case "sinh": .hyperbolicSine
        case "cosh": .hyperbolicCosine
        case "tanh": .hyperbolicTangent
        case "exp": .exponential
        case "log", "ln": .naturalLogarithm
        case "log10": .commonLogarithm
        case "sqrt": .squareRoot
        case "abs": .absoluteValue
        case "sgn", "sign": .sign
        case "floor": .floor
        case "ceil": .ceiling
        case "round", "nint": .round
        case "int": .truncate
        case "min": .minimum
        case "max": .maximum
        case "limit": .clamp
        case "pow": .power
        case "pwr": .positivePower
        case "pwrs": .signedPower
        default: nil
        }
    }

    private func validateArgumentCount(
        for function: BehavioralFunction,
        name: String,
        count: Int
    ) throws {
        let valid: Bool
        let expectation: String
        switch function {
        case .arcTangent2, .power, .positivePower, .signedPower:
            valid = count == 2
            expectation = "two"
        case .minimum, .maximum:
            valid = count >= 2
            expectation = "at least two"
        case .clamp:
            valid = count == 3
            expectation = "three"
        default:
            valid = count == 1
            expectation = "one"
        }
        guard valid else {
            throw LoweringError.invalidComponent(
                name: name,
                reason: "Behavioral function requires \(expectation) arguments"
            )
        }
    }

    private func nodeName(from expression: ParsedExpression) throws -> String {
        switch expression {
        case .identifier(let name):
            return name
        case .literal(let value) where value == 0:
            return "0"
        default:
            throw invalid(expression, "Voltage references require node names")
        }
    }

    private func resolveNodeName(_ name: String) -> String {
        if let external = portMapping[name] { return external }
        guard mapNodes, !prefix.isEmpty, name != "0",
              name.caseInsensitiveCompare("gnd") != .orderedSame,
              !name.contains(".") else {
            return name
        }
        return "\(prefix).\(name)"
    }

    private func registerNode(_ name: String, state: inout State, storage: FrontendStorage) throws {
        guard name != "0", name.caseInsensitiveCompare("gnd") != .orderedSame else {
            return
        }
        if !state.referencedNodeNameSet.contains(name.lowercased()) {
            try storage.budget.reserveSet(&state.referencedNodeNameSet, required: state.referencedNodeNameSet.count + 1)
            try storage.reserve(&state.referencedNodeNames, state.referencedNodeNames.count + 1)
            try storage.text(name); try storage.text(name.lowercased())
            state.referencedNodeNameSet.insert(name.lowercased())
            state.referencedNodeNames.append(name)
        }
    }

    private func invalid(
        _ expression: ParsedExpression,
        _ reason: String
    ) -> LoweringError {
        .expressionEvaluationFailed(expression: expression.description, reason: reason)
    }
}
