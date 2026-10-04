import CoreSpiceDevices
import CoreSpiceIR

/// Falsifies the new output-noise boundary while preserving actual electrical stamps.
struct OutputNoiseProbeDevice: OutputReferredNoisyDevice, NoisyDevice {
    enum Fault: Sendable { case doubleCount, negative, unknownNode, changedIdentity, overflow }
    let base: any BoundDevice
    let fault: Fault
    var instance: Instance { base.instance }
    var noiseTransferNodes: [Node] { fault == .unknownNode ? [Node(id: 99999)] : instance.nodes }
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws { try base.stampDC(into: &stamper, state: state) }
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws { try base.stampAC(into: &stamper, state: state, omega: omega) }
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) throws { try base.stampTransient(into: &stamper, state: state, integration: integration) }
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult { base.checkConvergence(state: state, previousState: previousState) }
    func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource] {
        [NoiseSource(name: "must_not_be_counted", positiveNode: instance.nodes[0], negativeNode: .ground, currentSpectralDensity: 1e99)]
    }
    func outputNoiseContributions(state: SolutionState, frequency: Double, gains: NoiseTransferGains) -> [OutputNoiseSource] {
        [OutputNoiseSource(name: fault == .changedIdentity && frequency > 1e3 ? "changed" : "probe",
            outputSpectralDensity: fault == .negative ? -1 : fault == .overflow ? 1e308 : 0)]
    }
}
