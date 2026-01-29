import CoreSpiceParsedIR
import CoreSpiceIR
import Synchronization

/// Context for the lowering process.
///
/// Maintains the parameter environment, model definitions, and
/// subcircuit definitions during lowering.
public final class LoweringContext: Sendable {

    /// Mutable state protected by Mutex.
    private struct MutableState {
        var parameters: [String: Double] = [:]
        var models: [String: ParsedModel] = [:]
        var subcircuits: [String: ParsedSubcircuit] = [:]
        var scopeStack: [[String: Double]] = []
        var depth: Int = 0
        var temperature: Double = 27.0
        var evaluatingParameters: Set<String> = []
    }

    private let state: Mutex<MutableState>

    /// Maximum allowed expansion depth.
    public let maxDepth: Int

    /// The current subcircuit expansion depth.
    public var depth: Int {
        state.withLock { $0.depth }
    }

    /// The default temperature in Celsius.
    public var temperature: Double {
        get { state.withLock { $0.temperature } }
        set { state.withLock { $0.temperature = newValue } }
    }

    /// Creates a new lowering context.
    public init(maxDepth: Int = 64) {
        self.maxDepth = maxDepth
        self.state = Mutex(MutableState())
    }

    // MARK: - Parameter Management

    /// Sets a parameter value.
    public func setParameter(_ name: String, value: Double) {
        state.withLock { $0.parameters[name.lowercased()] = value }
    }

    /// Gets a parameter value.
    public func parameter(_ name: String) -> Double? {
        state.withLock { state in
            let lowered = name.lowercased()
            // Check current scope first
            for scope in state.scopeStack.reversed() {
                if let value = scope[lowered] {
                    return value
                }
            }
            return state.parameters[lowered]
        }
    }

    /// Sets multiple parameters.
    public func setParameters(_ params: [String: Double]) {
        state.withLock { state in
            for (name, value) in params {
                state.parameters[name.lowercased()] = value
            }
        }
    }

    /// Marks a parameter as currently being evaluated (for cycle detection).
    /// Returns false if the parameter is already being evaluated (cycle detected).
    public func beginEvaluating(_ name: String) -> Bool {
        state.withLock { state in
            let lowered = name.lowercased()
            if state.evaluatingParameters.contains(lowered) {
                return false // Cycle detected
            }
            state.evaluatingParameters.insert(lowered)
            return true
        }
    }

    /// Marks a parameter as finished evaluating.
    public func endEvaluating(_ name: String) {
        _ = state.withLock { $0.evaluatingParameters.remove(name.lowercased()) }
    }

    // MARK: - Model Management

    /// Registers a model definition.
    public func registerModel(_ model: ParsedModel) {
        state.withLock { $0.models[model.name.lowercased()] = model }
    }

    /// Gets a model by name.
    public func model(_ name: String) -> ParsedModel? {
        state.withLock { $0.models[name.lowercased()] }
    }

    // MARK: - Subcircuit Management

    /// Registers a subcircuit definition.
    public func registerSubcircuit(_ subcircuit: ParsedSubcircuit) {
        state.withLock { state in
            state.subcircuits[subcircuit.name.lowercased()] = subcircuit

            // Also register nested subcircuits
            for nested in subcircuit.body.subcircuits {
                registerSubcircuitRecursive(nested, into: &state)
            }
        }
    }

    private func registerSubcircuitRecursive(_ subcircuit: ParsedSubcircuit, into state: inout MutableState) {
        state.subcircuits[subcircuit.name.lowercased()] = subcircuit
        for nested in subcircuit.body.subcircuits {
            registerSubcircuitRecursive(nested, into: &state)
        }
    }

    /// Gets a subcircuit by name.
    public func subcircuit(_ name: String) -> ParsedSubcircuit? {
        state.withLock { $0.subcircuits[name.lowercased()] }
    }

    // MARK: - Scope Management

    /// Enters a new scope for subcircuit expansion.
    public func enterScope(parameters: [String: Double] = [:]) throws {
        try state.withLock { state in
            state.depth += 1
            if state.depth > maxDepth {
                throw LoweringError.maxExpansionDepthExceeded(depth: maxDepth)
            }
            state.scopeStack.append(parameters)
        }
    }

    /// Exits the current scope.
    public func exitScope() {
        state.withLock { state in
            if !state.scopeStack.isEmpty {
                state.scopeStack.removeLast()
            }
            state.depth = max(0, state.depth - 1)
        }
    }

    /// Creates a scoped context for subcircuit expansion.
    public func withScope<T>(
        parameters: [String: Double] = [:],
        _ body: () throws -> T
    ) throws -> T {
        try enterScope(parameters: parameters)
        defer { exitScope() }
        return try body()
    }
}
