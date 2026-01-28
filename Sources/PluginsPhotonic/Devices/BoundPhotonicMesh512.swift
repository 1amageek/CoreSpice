import CoreSpiceIR
import CoreSpiceDevices

/// A bound 512-port photonic mesh device.
///
/// This device does not stamp into the electrical MNA matrix.
/// Instead, it serves as a marker that the circuit contains a
/// photonic mesh which should be simulated through the GPU
/// fast path provided by `PhotonicExecutor`.
public struct BoundPhotonicMesh512: BoundDevice, Sendable {

    public let instance: Instance

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // Photonic mesh: GPU-accelerated path, no MNA contribution.
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Photonic mesh: GPU-accelerated path, no MNA contribution.
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {
        // Photonic mesh: GPU-accelerated path, no MNA contribution.
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
