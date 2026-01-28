import CoreSpiceIR
import CoreSpiceDevices

/// A bound waveguide device ready for SPICE-level simulation.
///
/// Like other photonic devices, the waveguide does not contribute
/// to the electrical MNA system in DC/transient modes. In AC mode,
/// it could stamp a complex phase/loss transfer but the primary
/// simulation path is through the photonic mesh executor.
public struct BoundWaveguide: BoundDevice, Sendable {

    public let instance: Instance

    /// Physical length of the waveguide in meters.
    public let length: Double

    /// Effective refractive index of the guided mode.
    public let neff: Double

    /// Propagation loss in dB per centimeter.
    public let lossDBPerCm: Double

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // Photonic device: no contribution to electrical MNA.
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Photonic coupling handled through the mesh executor path.
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {
        // Photonic device: no contribution to electrical MNA.
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
