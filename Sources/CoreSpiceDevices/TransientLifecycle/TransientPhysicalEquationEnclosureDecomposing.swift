/// Separately admitted original static/reactive evaluation at represented paired coordinates.
public protocol TransientPhysicalEquationEnclosureDecomposing: BoundDevice {
    var transientPhysicalEquationForm: TransientPhysicalEquationForm { get }
    func validateTransientPhysicalEquationDecomposition() throws

    /// Supplies signed normalized centers and absolute radii in each compiled row's units.
    func accumulateTransientStaticResidualEnclosure(
        state: SolutionState, time: Double, add: (Int, CompensatedValue, Double) -> Void
    ) throws

    /// Supplies original static and explicitly typed reactive terms, preserving accepted history.
    func accumulateTransientPhysicalEquationEnclosure(
        state: SolutionState, integration: IntegrationState,
        add: (Int, TransientPhysicalEquationTerm, CompensatedValue, Double) -> Void
    ) throws
}
