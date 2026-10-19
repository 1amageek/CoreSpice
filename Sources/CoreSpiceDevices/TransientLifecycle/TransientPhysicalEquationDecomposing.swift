/// Supplies original static and explicitly typed reactive terms for whole-circuit BE/TR balance.
public protocol TransientPhysicalEquationDecomposing: BoundDevice {
    var transientPhysicalEquationForm: TransientPhysicalEquationForm { get }
    /// Refuses an incompatible physical law before the caller begins execution.
    func validateTransientPhysicalEquationDecomposition() throws

    /// Supplies F at the represented initial state and actual transient time.
    func accumulateTransientStaticResidual(
        state: SolutionState, time: Double, add: (Int, Double) -> Void
    ) throws

    /// Supplies F and conservative alphaDeltaQ or explicit differential-law terms.
    /// Scoped callbacks use compiled global equation rows; queries never promote history.
    func accumulateTransientPhysicalEquation(
        state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, Double) -> Void
    ) throws
}
