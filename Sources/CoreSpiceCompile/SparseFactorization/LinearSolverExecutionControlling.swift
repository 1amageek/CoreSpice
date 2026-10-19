/// Run-owned work, cancellation and managed-storage admission for a linear solver.
public protocol LinearSolverExecutionControlling: Sendable {
    /// Admit work before its execution and check cancellation, including for zero work.
    func checkpoint(workUnits: Int) throws

    /// Admit payload before allocation; retain the returned lease while it is live.
    func reserveStorage(byteCount: Int) throws -> any Sendable
}
