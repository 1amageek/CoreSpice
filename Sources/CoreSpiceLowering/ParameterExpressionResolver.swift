import CoreSpiceParsedIR

/// Resolves a set of SPICE parameter expressions against a lowering context.
///
/// SPICE decks often declare parameters in a dependency order that is useful to
/// humans but not guaranteed to match dictionary iteration order after parsing.
/// This resolver repeatedly evaluates resolvable expressions, publishes each
/// resolved value into the target scope, and fails only when no remaining
/// expression can make progress.
public struct ParameterExpressionResolver: Sendable {

    private let context: LoweringContext
    private let randomUniform: @Sendable () -> Double

    public init(
        context: LoweringContext,
        randomUniform: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.context = context
        self.randomUniform = randomUniform
    }

    /// Resolves top-level `.param` expressions into the global parameter scope.
    @discardableResult
    public func resolveGlobal(_ parameters: [String: ParsedExpression]) throws -> [String: Double] {
        let values = parameters.mapValues { ParsedParameterValue.expression($0) }
        return try resolve(values) { name, value in
            context.setParameter(name, value: value)
        }
    }

    /// Resolves parameter values into the currently active scope.
    @discardableResult
    public func resolveIntoCurrentScope(_ parameters: [String: ParsedParameterValue]) throws -> [String: Double] {
        try resolve(parameters) { name, value in
            try context.setScopedParameter(name, value: value)
        }
    }

    /// Resolves values in a temporary local scope and returns the resolved map.
    ///
    /// The temporary scope lets parameters in the same declaration set refer to
    /// each other without leaking model-local or subcircuit-default names into
    /// the parent/global parameter environment.
    public func resolveInTemporaryScope(_ parameters: [String: ParsedParameterValue]) throws -> [String: Double] {
        try context.withScope(parameters: [:]) {
            try resolveIntoCurrentScope(parameters)
        }
    }

    private func resolve(
        _ parameters: [String: ParsedParameterValue],
        publish: (String, Double) throws -> Void
    ) throws -> [String: Double] {
        var pending = parameters
        var resolved: [String: Double] = [:]
        var lastFailure: Error?
        let evaluator = ExpressionEvaluator(context: context, randomUniform: randomUniform)

        while !pending.isEmpty {
            var progressed = false

            for name in pending.keys.sorted() {
                guard let expression = pending[name] else {
                    continue
                }

                do {
                    let value = try evaluator.evaluate(expression)
                    try publish(name, value)
                    resolved[name.lowercased()] = value
                    pending.removeValue(forKey: name)
                    progressed = true
                } catch {
                    lastFailure = error
                }
            }

            if !progressed {
                if let lastFailure {
                    throw lastFailure
                }
                throw LoweringError.expressionEvaluationFailed(
                    expression: pending.keys.sorted().joined(separator: ", "),
                    reason: "Could not resolve parameter dependency graph"
                )
            }
        }

        return resolved
    }
}
