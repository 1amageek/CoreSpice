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

    /// Only explicit instance assignments may read their own caller binding.
    func resolveInstanceParameters(
        _ parameters: [String: ParsedParameterValue],
        callerReferenceNames: Set<String>
    ) throws -> [String: Double] {
        try context.withScope(parameters: [:]) {
            try resolve(parameters, reservesLocalNames: true, callerReferenceNames: callerReferenceNames) { name, value in
                try context.setScopedParameter(name, value: value)
            }
        }
    }

    private func resolve(
        _ parameters: [String: ParsedParameterValue],
        reservesLocalNames: Bool = false,
        callerReferenceNames: Set<String> = [],
        publish: (String, Double) throws -> Void
    ) throws -> [String: Double] {
        var pending = parameters
        if reservesLocalNames {
            pending = [:]
            for name in parameters.keys.sorted() {
                pending[name.lowercased()] = parameters[name]
            }
        }
        let callerNames = Set(callerReferenceNames.map { $0.lowercased() })
        var resolved: [String: Double] = [:]

        while !pending.isEmpty {
            var progressed = false
            var blockedReferences: [String: String] = [:]
            var failure: Error?

            for name in pending.keys.sorted() {
                guard let expression = pending[name] else {
                    continue
                }

                do {
                    var unresolvedNames = reservesLocalNames ? Set(pending.keys) : []
                    if callerNames.contains(name) {
                        unresolvedNames.remove(name)
                    }
                    let evaluator = ExpressionEvaluator(
                        context: context,
                        randomUniform: randomUniform,
                        unresolvedParameterNames: unresolvedNames
                    )
                    let value = try evaluator.evaluate(expression)
                    try publish(name, value)
                    resolved[name.lowercased()] = value
                    pending.removeValue(forKey: name)
                    progressed = true
                } catch let reference as ExpressionEvaluator.UnresolvedParameterReference {
                    blockedReferences[name] = reference.name
                } catch {
                    failure = error
                }
            }

            if !progressed {
                if let failure {
                    throw failure
                }
                // Every remaining assignment waits for another pending local.
                // Following these observed references identifies a real cycle,
                // including references inside the evaluated conditional branch.
                var visited: Set<String> = []
                var name = pending.keys.sorted().first!
                while visited.insert(name).inserted, let dependency = blockedReferences[name] {
                    name = dependency
                }
                throw LoweringError.circularParameterDependency(parameter: name)
            }
        }

        return resolved
    }
}
