import CoreSpiceMOSContracts

/// Arguments are a borrowed range in the interpreter's admitted value stack.
package func builtinMOSValue(_ name: String, symbol: MOSSymbolID, arguments: ArraySlice<Double>,
                             session: inout MOSEvaluationSession) throws(MOSResolutionFailure) -> Double? {
    let base = arguments.startIndex
    func require(_ count: Int) throws(MOSResolutionFailure) {
        guard arguments.count == count else { throw .invalidFunctionArity(symbol) }
    }
    func unary() throws(MOSResolutionFailure) -> Double { try require(1); return arguments[base] }
    let result: Double
    switch name {
    case "sin": result = MOSMath.sine(try unary())
    case "cos": result = MOSMath.cosine(try unary())
    case "tan": result = MOSMath.tangent(try unary())
    case "asin": result = MOSMath.arcSine(try unary())
    case "acos": result = MOSMath.arcCosine(try unary())
    case "atan": result = MOSMath.arcTangent(try unary())
    case "atan2": try require(2); result = MOSMath.arcTangent2(arguments[base], arguments[base + 1])
    case "sinh": result = MOSMath.hyperbolicSine(try unary())
    case "cosh": result = MOSMath.hyperbolicCosine(try unary())
    case "tanh": result = MOSMath.hyperbolicTangent(try unary())
    case "exp": result = MOSMath.exponential(try unary())
    case "ln", "log": result = MOSMath.logarithm(try unary())
    case "log10": result = MOSMath.logarithm10(try unary())
    case "sqrt": result = MOSMath.squareRoot(try unary())
    case "pow": try require(2); result = MOSMath.power(arguments[base], arguments[base + 1])
    case "pwr": try require(2); result = MOSMath.power(abs(arguments[base]), arguments[base + 1])
    case "pwrs":
        try require(2)
        let magnitude = MOSMath.power(abs(arguments[base]), arguments[base + 1])
        result = arguments[base] < 0 ? -magnitude : magnitude
    case "abs": result = abs(try unary())
    case "sgn", "sign": let value = try unary(); result = value > 0 ? 1 : (value < 0 ? -1 : 0)
    case "floor": result = try unary().rounded(.down)
    case "ceil": result = try unary().rounded(.up)
    case "round", "nint": result = try unary().rounded(.toNearestOrAwayFromZero)
    case "int": result = try unary().rounded(.towardZero)
    case "db": result = 20 * MOSMath.logarithm10(abs(try unary()))
    case "min", "max":
        guard arguments.count >= 2 else { throw .invalidFunctionArity(symbol) }
        var value = arguments[base]
        for next in arguments.dropFirst() {
            try session.spend(.evaluationSteps)
            value = name == "min" ? min(value, next) : max(value, next)
        }
        result = value
    case "if": try require(3); result = arguments[base] != 0 ? arguments[base + 1] : arguments[base + 2]
    case "limit": try require(3); result = min(max(arguments[base], arguments[base + 1]), arguments[base + 2])
    case "rand", "random": try require(0); result = try session.drawRandom()
    case "gauss", "agauss":
        guard arguments.count == 2 || arguments.count == 3 else { throw .invalidFunctionArity(symbol) }
        if arguments.count == 3, arguments[base + 2] <= 0 { throw .invalidFunctionDomain(symbol) }
        let u1 = max(try session.drawRandom(), Double.leastNonzeroMagnitude)
        let u2 = try session.drawRandom()
        let sample = MOSMath.squareRoot(-2 * MOSMath.logarithm(u1)) * MOSMath.cosine(2 * .pi * u2)
        let spread = arguments.count == 3 && name == "gauss" ? arguments[base] * arguments[base + 1] : arguments[base + 1]
        result = arguments[base] + spread / (arguments.count == 3 ? arguments[base + 2] : 1) * sample
    default: return nil
    }
    guard result.isFinite else { throw .invalidFunctionDomain(symbol) }
    return result
}
