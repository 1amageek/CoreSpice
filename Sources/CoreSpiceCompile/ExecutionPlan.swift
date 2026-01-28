import CoreSpiceIR

/// The compiled execution plan for a circuit simulation.
///
/// Contains everything needed to set up and run an analysis:
/// the circuit IR, matrix topology, sparsity structure, and
/// an ordered list of device instance names.
///
/// Device model bindings are not stored here because they belong
/// to the ``CoreSpiceDevices`` module, which ``CoreSpiceCompile``
/// does not depend on.
public struct ExecutionPlan: Sendable {

    /// The circuit intermediate representation.
    public let ir: CircuitIR

    /// The MNA matrix topology mapping variables to indices.
    public let topology: MatrixTopology

    /// The CSR sparsity pattern for the MNA system matrix.
    public let matrixStructure: SparseStructure

    /// Ordered list of device instance names matching ``CircuitIR/instances``.
    public let deviceNames: [String]

    public init(
        ir: CircuitIR,
        topology: MatrixTopology,
        matrixStructure: SparseStructure,
        deviceNames: [String]
    ) {
        self.ir = ir
        self.topology = topology
        self.matrixStructure = matrixStructure
        self.deviceNames = deviceNames
    }
}
