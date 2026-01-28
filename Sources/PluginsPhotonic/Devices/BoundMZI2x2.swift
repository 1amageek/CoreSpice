import CoreSpiceIR
import CoreSpiceDevices

/// A bound 2x2 MZI device ready for SPICE-level simulation.
///
/// In DC and transient modes the MZI acts as a pass-through
/// (photonic devices do not contribute to electrical MNA).
/// In AC mode the complex transfer matrix can be stamped to
/// model interference effects at a linearised operating point.
public struct BoundMZI2x2: BoundDevice, Sendable {

    public let instance: Instance

    /// Internal phase shift in radians.
    public let theta: Double

    /// External phase in radians.
    public let phi: Double

    /// Insertion loss (linear, 0--1).
    public let loss: Double

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        // MZI in DC: photonic device, no contribution to electrical MNA.
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Stamp complex transfer matrix at AC frequency.
        // Photonic coupling is handled through the mesh executor path;
        // this stub exists for compatibility with the BoundDevice protocol.
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {
        // Same as DC for photonic device.
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}
