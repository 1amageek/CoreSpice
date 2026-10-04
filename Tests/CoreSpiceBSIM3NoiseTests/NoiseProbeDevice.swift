import CoreSpiceDevices
import CoreSpiceIR

/// Keeps the production electrical device while falsifying one noise invariant.
struct NoiseProbeDevice: NoisyDevice {
    enum Fault: Sendable { case coincident, negative, unknownNode, changedIdentity, overflow }
    let base: any BoundDevice
    let fault: Fault
    var instance: Instance { base.instance }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try base.stampAC(into: &stamper, state: state, omega: omega)
    }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws {
        try base.stampTransient(into: &stamper, state: state, integration: integration)
    }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        base.checkConvergence(state: state, previousState: previousState)
    }
    func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource] {
        let node = instance.nodes[0]
        return [NoiseSource(name: fault == .changedIdentity && frequency > 1e3 ? "changed" : "probe",
            positiveNode: fault == .unknownNode ? Node(id: 1_000_000) : node,
            negativeNode: fault == .coincident ? node : .ground,
            currentSpectralDensity: fault == .negative ? -1 : fault == .overflow ? 1e308 : 1e-20)]
    }
}
