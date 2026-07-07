import CoreSpiceParsedIR
import Foundation

/// Evaluates parsed expressions to numeric values.
public struct ExpressionEvaluator: Sendable {

    /// The context providing parameter values.
    private let context: LoweringContext
    /// Source of random numbers in [0, 1).
    private let randomUniform: @Sendable () -> Double

    public init(
        context: LoweringContext,
        randomUniform: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.context = context
        self.randomUniform = randomUniform
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

        case .unaryOperation(let operation, let inner):
            let value = try evaluate(inner)
            switch operation {
            case .negate:
                return -value
            case .not:
                return value == 0 ? 1 : 0
            case .plus:
                return value
            }

        case .binaryOperation(let operation, let lhs, let rhs):
            let left = try evaluate(lhs)
            let right = try evaluate(rhs)
            return try evaluateBinaryOperation(operation, left, right)

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

    private func evaluateBinaryOperation(
        _ operation: BinaryOperator,
        _ left: Double,
        _ right: Double
    ) throws -> Double {
        switch operation {
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

        if let value = try evaluateTrigonometricFunction(lowered, originalName: name, arguments: args) {
            return value
        }
        if let value = try evaluateExponentialFunction(lowered, originalName: name, arguments: args) {
            return value
        }
        if let value = try evaluateNumericUtilityFunction(lowered, originalName: name, arguments: args) {
            return value
        }
        if let value = try evaluateSpiceSpecificFunction(lowered, originalName: name, arguments: args) {
            return value
        }
        if let value = try evaluateRandomFunction(lowered, originalName: name, arguments: args) {
            return value
        }
        if let function = context.function(lowered) {
            return try evaluateUserFunction(function, arguments: args)
        }
        throw LoweringError.expressionEvaluationFailed(
            expression: name,
            reason: "Unknown function: \(name)"
        )
    }

    private func evaluateTrigonometricFunction(
        _ name: String,
        originalName: String,
        arguments: [Double]
    ) throws -> Double? {
        switch name {
        case "sin":
            return sin(try unaryArgument(originalName, arguments))
        case "cos":
            return cos(try unaryArgument(originalName, arguments))
        case "tan":
            return tan(try unaryArgument(originalName, arguments))
        case "asin":
            return asin(try unaryArgument(originalName, arguments))
        case "acos":
            return acos(try unaryArgument(originalName, arguments))
        case "atan":
            return atan(try unaryArgument(originalName, arguments))
        case "atan2":
            let (y, x) = try binaryArguments(originalName, arguments)
            return atan2(y, x)
        case "sinh":
            return sinh(try unaryArgument(originalName, arguments))
        case "cosh":
            return cosh(try unaryArgument(originalName, arguments))
        case "tanh":
            return tanh(try unaryArgument(originalName, arguments))
        default:
            return nil
        }
    }

    private func evaluateExponentialFunction(
        _ name: String,
        originalName: String,
        arguments: [Double]
    ) throws -> Double? {
        switch name {
        case "exp":
            return exp(try unaryArgument(originalName, arguments))
        case "log", "ln":
            return log(try unaryArgument(originalName, arguments))
        case "log10":
            return log10(try unaryArgument(originalName, arguments))
        case "sqrt":
            return sqrt(try unaryArgument(originalName, arguments))
        case "pow":
            let (base, exponent) = try binaryArguments(originalName, arguments)
            return pow(base, exponent)
        default:
            return nil
        }
    }

    private func evaluateNumericUtilityFunction(
        _ name: String,
        originalName: String,
        arguments: [Double]
    ) throws -> Double? {
        switch name {
        case "abs":
            return abs(try unaryArgument(originalName, arguments))
        case "sgn", "sign":
            let value = try unaryArgument(originalName, arguments)
            return value > 0 ? 1 : (value < 0 ? -1 : 0)
        case "floor":
            return floor(try unaryArgument(originalName, arguments))
        case "ceil":
            return ceil(try unaryArgument(originalName, arguments))
        case "round", "nint":
            return round(try unaryArgument(originalName, arguments))
        case "int":
            return Double(Int(try unaryArgument(originalName, arguments)))
        case "min":
            return try variadicArguments(originalName, arguments, minimumCount: 2).min()
        case "max":
            return try variadicArguments(originalName, arguments, minimumCount: 2).max()
        case "if":
            let (condition, trueValue, falseValue) = try ternaryArguments(originalName, arguments)
            return condition != 0 ? trueValue : falseValue
        case "limit":
            let (value, lower, upper) = try ternaryArguments(originalName, arguments)
            return Swift.min(Swift.max(value, lower), upper)
        default:
            return nil
        }
    }

    private func evaluateSpiceSpecificFunction(
        _ name: String,
        originalName: String,
        arguments: [Double]
    ) throws -> Double? {
        switch name {
        case "pwr", "pwrs":
            let (base, exponent) = try binaryArguments(originalName, arguments)
            return pow(abs(base), exponent)
        case "db":
            return 20 * log10(abs(try unaryArgument(originalName, arguments)))
        default:
            return nil
        }
    }

    private func evaluateRandomFunction(
        _ name: String,
        originalName: String,
        arguments: [Double]
    ) throws -> Double? {
        switch name {
        case "rand", "random":
            try requireArgumentCount(originalName, arguments, expected: 0)
            return randomUniform()
        case "gauss":
            return try evaluateGaussian(originalName, arguments: arguments, relativeVariation: true)
        case "agauss":
            return try evaluateGaussian(originalName, arguments: arguments, relativeVariation: false)
        default:
            return nil
        }
    }

    private func evaluateGaussian(
        _ function: String,
        arguments: [Double],
        relativeVariation: Bool
    ) throws -> Double {
        let z = try gaussianUnitSample(function)
        switch arguments.count {
        case 2:
            return arguments[0] + arguments[1] * z
        case 3:
            let sigma = arguments[2]
            guard sigma > 0 else {
                throw LoweringError.expressionEvaluationFailed(
                    expression: function,
                    reason: "Gaussian sigma divisor must be positive"
                )
            }
            let spread = relativeVariation ? arguments[0] * arguments[1] : arguments[1]
            return arguments[0] + spread / sigma * z
        default:
            throw argCountError(function, expected: "2 or 3", got: arguments.count)
        }
    }

    private func gaussianUnitSample(_ function: String) throws -> Double {
        let u1 = randomUniform()
        let u2 = randomUniform()
        guard u1.isFinite, u2.isFinite, u1 >= 0, u1 < 1, u2 >= 0, u2 < 1 else {
            throw LoweringError.expressionEvaluationFailed(
                expression: function,
                reason: "Random source returned a value outside [0, 1)"
            )
        }
        let positiveU1 = Swift.max(u1, Double.leastNonzeroMagnitude)
        return sqrt(-2 * log(positiveU1)) * cos(2 * .pi * u2)
    }

    private func evaluateUserFunction(_ function: UserFunctionDefinition, arguments: [Double]) throws -> Double {
        guard function.parameters.count == arguments.count else {
            throw argCountError(function.name, expected: function.parameters.count, got: arguments.count)
        }
        guard context.beginEvaluatingFunction(function.name) else {
            throw LoweringError.expressionEvaluationFailed(
                expression: function.name,
                reason: "Recursive function evaluation is not supported"
            )
        }
        defer { context.endEvaluatingFunction(function.name) }

        var scopedParameters: [String: Double] = [:]
        for (name, value) in zip(function.parameters, arguments) {
            scopedParameters[name] = value
        }
        return try context.withScope(parameters: scopedParameters) {
            try evaluate(function.body)
        }
    }

    private func unaryArgument(_ function: String, _ arguments: [Double]) throws -> Double {
        try requireArgumentCount(function, arguments, expected: 1)
        return arguments[0]
    }

    private func binaryArguments(_ function: String, _ arguments: [Double]) throws -> (Double, Double) {
        try requireArgumentCount(function, arguments, expected: 2)
        return (arguments[0], arguments[1])
    }

    private func ternaryArguments(_ function: String, _ arguments: [Double]) throws -> (Double, Double, Double) {
        try requireArgumentCount(function, arguments, expected: 3)
        return (arguments[0], arguments[1], arguments[2])
    }

    private func variadicArguments(
        _ function: String,
        _ arguments: [Double],
        minimumCount: Int
    ) throws -> [Double] {
        guard arguments.count >= minimumCount else {
            throw argCountError(function, expected: minimumCount, got: arguments.count)
        }
        return arguments
    }

    private func requireArgumentCount(_ function: String, _ arguments: [Double], expected: Int) throws {
        guard arguments.count == expected else {
            throw argCountError(function, expected: expected, got: arguments.count)
        }
    }

    private func argCountError(_ function: String, expected: Int, got: Int) -> LoweringError {
        argCountError(function, expected: "\(expected)", got: got)
    }

    private func argCountError(_ function: String, expected: String, got: Int) -> LoweringError {
        LoweringError.expressionEvaluationFailed(
            expression: function,
            reason: "Expected \(expected) arguments, got \(got)"
        )
    }
}
