import CoreSpiceIR
import CoreSpiceParsedIR

/// Converts parsed SPICE expressions into canonical simulation-time expressions.
struct BehavioralExpressionLowerer {
    struct Result {
        let expression: BehavioralExpression
        let referencedNodeNames: [String]
        let referencedBranchNames: [String]
    }

    private struct State {
        var referencedNodeNames: [String] = []
        var referencedNodeNameSet: Set<String> = []
        var referencedBranchNames: [String] = []
        var branchReferenceIndices: [String: Int] = [:]
        var evaluatingFunctions: Set<String> = []
    }

    private let context: LoweringContext
    private let prefix: String
    private let mapNodes: Bool

    init(context: LoweringContext, prefix: String, mapNodes: Bool) {
        self.context = context
        self.prefix = prefix
        self.mapNodes = mapNodes
    }

    func lower(
        _ expression: ParsedExpression,
        into builder: inout Netlist
    ) throws -> Result {
        var state = State()
        let lowered = try lower(
            expression,
            bindings: [:],
            state: &state,
            builder: &builder
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
        builder: inout Netlist
    ) throws -> BehavioralExpression {
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
            if name.caseInsensitiveCompare("pi") == .orderedSame {
                return .constant(.pi)
            }
            guard let value = context.parameter(name), value.isFinite else {
                throw invalid(
                    expression,
                    "Identifier '\(name)' is neither a finite parameter nor the time variable"
                )
            }
            return .constant(value)

        case .unaryOperation(let operation, let operand):
            let mapped: BehavioralUnaryOperator = switch operation {
            case .negate: .negate
            case .not: .logicalNot
            case .plus: .plus
            }
            return .unary(
                mapped,
                try lower(
                    operand,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                )
            )

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
            return .binary(
                mapped,
                try lower(
                    lhs,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                ),
                try lower(
                    rhs,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                )
            )

        case .functionCall(let name, let arguments):
            return try lowerFunction(
                name: name,
                arguments: arguments,
                bindings: bindings,
                state: &state,
                builder: &builder
            )

        case .conditional(let condition, let then, let `else`):
            return .conditional(
                condition: try lower(
                    condition,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                ),
                then: try lower(
                    then,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                ),
                else: try lower(
                    `else`,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                )
            )
        }
    }

    private func lowerFunction(
        name: String,
        arguments: [ParsedExpression],
        bindings: [String: BehavioralExpression],
        state: inout State,
        builder: inout Netlist
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
            registerNode(resolvedPositiveName, state: &state)
            registerNode(resolvedNegativeName, state: &state)
            return .variable(
                .nodeVoltage(
                    positive: builder.node(resolvedPositiveName),
                    negative: builder.node(resolvedNegativeName)
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
            return .conditional(
                condition: try lower(
                    arguments[0],
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                ),
                then: try lower(
                    arguments[1],
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                ),
                else: try lower(
                    arguments[2],
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                )
            )
        }

        if let definition = context.function(loweredName) {
            guard definition.parameters.count == arguments.count else {
                throw LoweringError.invalidComponent(
                    name: name,
                    reason: "Behavioral function requires \(definition.parameters.count) arguments"
                )
            }
            guard state.evaluatingFunctions.insert(loweredName).inserted else {
                throw invalid(
                    .functionCall(name: name, arguments: arguments),
                    "Recursive behavioral function evaluation is not supported"
                )
            }
            defer { state.evaluatingFunctions.remove(loweredName) }

            var functionBindings = bindings
            for (parameter, argument) in zip(definition.parameters, arguments) {
                functionBindings[parameter.lowercased()] = try lower(
                    argument,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                )
            }
            return try lower(
                definition.body,
                bindings: functionBindings,
                state: &state,
                builder: &builder
            )
        }

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
        return .function(
            function,
            try arguments.map {
                try lower(
                    $0,
                    bindings: bindings,
                    state: &state,
                    builder: &builder
                )
            }
        )
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
        guard mapNodes, !prefix.isEmpty, name != "0",
              name.caseInsensitiveCompare("gnd") != .orderedSame,
              !name.contains(".") else {
            return name
        }
        return "\(prefix).\(name)"
    }

    private func registerNode(_ name: String, state: inout State) {
        guard name != "0", name.caseInsensitiveCompare("gnd") != .orderedSame else {
            return
        }
        if state.referencedNodeNameSet.insert(name.lowercased()).inserted {
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
