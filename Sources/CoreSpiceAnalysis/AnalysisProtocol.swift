import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

/// A circuit analysis that can be executed against a compiled execution plan.
///
/// Each analysis type (DC, AC, transient) conforms to this protocol and
/// provides its own result type. The protocol ensures that all analyses
/// share a common execution interface while remaining type-safe through
/// the associated `Result` type.
public protocol Analysis: Sendable {

    /// The type of result produced by this analysis.
    associatedtype Result: Sendable

    /// Executes the analysis.
    ///
    /// - Parameters:
    ///   - plan: The compiled execution plan describing the circuit topology and matrix structure.
    ///   - devices: The bound device instances that stamp into the MNA system.
    ///   - solver: The linear solver used for matrix factorization and back-substitution.
    ///   - observer: An optional event dispatcher for emitting progress and diagnostic events.
    ///   - cancellation: A token that can be checked or triggered to cancel the analysis.
    /// - Returns: The analysis result.
    /// - Throws: ``AnalysisError`` on convergence failure, cancellation, or other issues.
    func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> Result
}
