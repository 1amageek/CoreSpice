import CoreSpiceParsedIR
import Foundation

/// Evaluates parsed expressions to numeric values.
public struct ExpressionEvaluator: Sendable {

    /// The context providing parameter values.
    private let context: LoweringContext

    public init(context: LoweringContext) {
        self.context = context
    }

    /// Evaluates an expression to a numeric value.
    public func evaluate(_ expression: ParsedExpression) throws -> Double {
        switch expression {
        case .literal(let value):
            return value

        case .identifier(let name):
            // Check for circular reference
            guard context.beginEvaluating(name) else {
                throw LoweringError.circularParameterDependency(parameter: name)
            }
            defer { context.endEvaluating(name) }

            guard let value = context.parameter(name) else {
                throw LoweringError.undefinedParameter(name: name, location: nil)
            }
            return value

        case .unaryOp(let op, let inner):
            let value = try evaluate(inner)
            switch op {
            case .negate:
                return -value
            case .not:
                return value == 0 ? 1 : 0
            case .plus:
                return value
            }

        case .binaryOp(let op, let lhs, let rhs):
            let left = try evaluate(lhs)
            let right = try evaluate(rhs)
            return try evaluateBinaryOp(op, left, right)

        case .functionCall(let name, let arguments):
            let args = try arguments.map { try evaluate($0) }
            return try evaluateFunction(name, args)

        case .conditional(let condition, let then, let `else`):
            let cond = try evaluate(condition)
            if cond != 0 {
                return try evaluate(then)
            } else {
                return try evaluate(`else`)
            }
        }
    }

    /// Evaluates a parameter value.
    public func evaluate(_ value: ParsedParameterValue) throws -> Double {
        switch value {
        case .numeric(let n):
            return n
        case .string:
            throw LoweringError.expressionEvaluationFailed(
                expression: "string",
                reason: "Cannot evaluate string as number"
            )
        case .expression(let expr):
            return try evaluate(expr)
        case .boolean(let b):
            return b ? 1.0 : 0.0
        }
    }

    // MARK: - Private Helpers

    private func evaluateBinaryOp(
        _ op: BinaryOperator,
        _ left: Double,
        _ right: Double
    ) throws -> Double {
        switch op {
        case .add:
            return left + right
        case .subtract:
            return left - right
        case .multiply:
            return left * right
        case .divide:
            guard right != 0 else {
                throw LoweringError.expressionEvaluationFailed(
                    expression: "\(left) / \(right)",
                    reason: "Division by zero"
                )
            }
            return left / right
        case .power:
            return pow(left, right)
        case .modulo:
            guard right != 0 else {
                throw LoweringError.expressionEvaluationFailed(
                    expression: "\(left) % \(right)",
                    reason: "Modulo by zero"
                )
            }
            return left.truncatingRemainder(dividingBy: right)
        case .equal:
            return left == right ? 1 : 0
        case .notEqual:
            return left != right ? 1 : 0
        case .lessThan:
            return left < right ? 1 : 0
        case .lessOrEqual:
            return left <= right ? 1 : 0
        case .greaterThan:
            return left > right ? 1 : 0
        case .greaterOrEqual:
            return left >= right ? 1 : 0
        case .and:
            return (left != 0 && right != 0) ? 1 : 0
        case .or:
            return (left != 0 || right != 0) ? 1 : 0
        }
    }

    private func evaluateFunction(_ name: String, _ args: [Double]) throws -> Double {
        let lowered = name.lowercased()

        switch lowered {
        // Trigonometric
        case "sin":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return sin(args[0])
        case "cos":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return cos(args[0])
        case "tan":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return tan(args[0])
        case "asin":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return asin(args[0])
        case "acos":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return acos(args[0])
        case "atan":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return atan(args[0])
        case "atan2":
            guard args.count == 2 else { throw argCountError(name, expected: 2, got: args.count) }
            return atan2(args[0], args[1])
        case "sinh":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return sinh(args[0])
        case "cosh":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return cosh(args[0])
        case "tanh":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return tanh(args[0])

        // Exponential / Logarithmic
        case "exp":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return exp(args[0])
        case "log", "ln":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return log(args[0])
        case "log10":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return log10(args[0])
        case "sqrt":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return sqrt(args[0])
        case "pow":
            guard args.count == 2 else { throw argCountError(name, expected: 2, got: args.count) }
            return pow(args[0], args[1])

        // Absolute / Sign
        case "abs":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return abs(args[0])
        case "sgn", "sign":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return args[0] > 0 ? 1 : (args[0] < 0 ? -1 : 0)

        // Rounding
        case "floor":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return floor(args[0])
        case "ceil":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return ceil(args[0])
        case "round", "nint":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return round(args[0])
        case "int":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return Double(Int(args[0]))

        // Min / Max
        case "min":
            guard args.count >= 2 else { throw argCountError(name, expected: 2, got: args.count) }
            return args.min() ?? 0
        case "max":
            guard args.count >= 2 else { throw argCountError(name, expected: 2, got: args.count) }
            return args.max() ?? 0

        // Conditional
        case "if":
            guard args.count == 3 else { throw argCountError(name, expected: 3, got: args.count) }
            return args[0] != 0 ? args[1] : args[2]

        // Limit
        case "limit":
            guard args.count == 3 else { throw argCountError(name, expected: 3, got: args.count) }
            return Swift.min(Swift.max(args[0], args[1]), args[2])

        // SPICE-specific
        case "pwr", "pwrs":
            guard args.count == 2 else { throw argCountError(name, expected: 2, got: args.count) }
            return pow(abs(args[0]), args[1])

        case "db":
            guard args.count == 1 else { throw argCountError(name, expected: 1, got: args.count) }
            return 20 * log10(abs(args[0]))

        // Random (deterministic seed for reproducibility in SPICE)
        case "rand", "random":
            return Double.random(in: 0..<1)

        case "gauss", "agauss":
            guard args.count >= 2 else { throw argCountError(name, expected: 2, got: args.count) }
            // Simple Box-Muller for Gaussian
            let u1 = Double.random(in: 0..<1)
            let u2 = Double.random(in: 0..<1)
            let z = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
            return args[0] + args[1] * z

        default:
            throw LoweringError.expressionEvaluationFailed(
                expression: name,
                reason: "Unknown function: \(name)"
            )
        }
    }

    private func argCountError(_ function: String, expected: Int, got: Int) -> LoweringError {
        LoweringError.expressionEvaluationFailed(
            expression: function,
            reason: "Expected \(expected) arguments, got \(got)"
        )
    }
}
