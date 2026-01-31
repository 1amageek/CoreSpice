import CoreSpiceIR

/// A directed acyclic graph (DAG) representing the optical signal propagation network.
///
/// The graph is topologically sorted so that evaluation proceeds from
/// light sources (emitters) through passive devices (waveguides, splitters)
/// to detectors (photodiodes). This ordering ensures that when a device
/// is evaluated, all its input signals are already available.
///
/// **Limitations**: This DAG structure does not support optical feedback
/// (ring resonators, Fabry-Perot cavities) or bidirectional coupling.
/// These would require self-consistent field (SCF) iteration.
public struct OpticalNetworkGraph: Sendable {

    /// An entry in the evaluation order.
    public struct EvaluationEntry: Sendable {
        /// Index into the devices array identifying which device to evaluate.
        public let deviceIndex: Int

        /// The optical input nodes this device reads from.
        public let inputNodes: [OpticalNode]

        /// The optical output nodes this device writes to.
        public let outputNodes: [OpticalNode]

        public init(deviceIndex: Int, inputNodes: [OpticalNode], outputNodes: [OpticalNode]) {
            self.deviceIndex = deviceIndex
            self.inputNodes = inputNodes
            self.outputNodes = outputNodes
        }
    }

    /// Topologically sorted evaluation order.
    /// Devices with no optical inputs come first (emitters),
    /// followed by passive devices, and finally receivers.
    public let evaluationOrder: [EvaluationEntry]

    /// Total number of optical nodes (determines OpticalState array size).
    public let opticalNodeCount: Int

    public init(evaluationOrder: [EvaluationEntry], opticalNodeCount: Int) {
        self.evaluationOrder = evaluationOrder
        self.opticalNodeCount = opticalNodeCount
    }
}
