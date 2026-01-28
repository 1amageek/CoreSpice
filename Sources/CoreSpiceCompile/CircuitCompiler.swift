import CoreSpiceIR

/// A type that compiles a circuit IR into an execution plan.
public protocol CircuitCompiler: Sendable {

    /// Compiles the given circuit into an execution plan.
    ///
    /// - Throws: ``CompileError`` if the circuit cannot be compiled.
    func compile(ir: CircuitIR) throws -> ExecutionPlan
}

/// The default circuit compiler.
///
/// Builds the MNA matrix topology from the circuit IR and packages
/// it into an ``ExecutionPlan``.
public struct StandardCompiler: CircuitCompiler {

    public init() {}

    public func compile(ir: CircuitIR) throws -> ExecutionPlan {
        guard !ir.instances.isEmpty else {
            throw CompileError.emptyCircuit
        }

        let topology = MatrixTopology(ir: ir)

        return ExecutionPlan(
            ir: ir,
            topology: topology,
            matrixStructure: topology.structure,
            deviceNames: ir.instances.map(\.name)
        )
    }
}
