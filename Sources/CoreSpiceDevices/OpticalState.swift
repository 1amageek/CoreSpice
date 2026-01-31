import CoreSpiceIR

/// Snapshot of the optical network state at a given point.
///
/// Stores optical signals at each optical node using a contiguous array
/// indexed by `OpticalNode.id` for O(1) access. This is critical for
/// performance when the optical network is evaluated at every NR iteration.
///
/// Also carries the sensitivity map `dP/dV` computed by forward-mode
/// propagation through the optical DAG. These sensitivities are used
/// by optoelectronic receivers (e.g., photodiodes) to stamp the correct
/// Jacobian entries for NR convergence.
public struct OpticalState: Sendable {

    /// Number of optical nodes (array size).
    public let nodeCount: Int

    /// Optical signals at each node, indexed by OpticalNode.id.
    public var signals: [OpticalSignal]

    /// Sensitivity map: dP_optical / dV_electrical.
    /// Populated during DAG evaluation via forward-mode sensitivity propagation.
    public var sensitivities: OpticalSensitivityMap

    public init(nodeCount: Int = 0) {
        self.nodeCount = nodeCount
        self.signals = [OpticalSignal](repeating: .zero, count: nodeCount)
        self.sensitivities = OpticalSensitivityMap()
    }

    /// Returns the optical power at the given node.
    public func power(at node: OpticalNode) -> Double {
        guard node.id > 0, node.id < nodeCount else { return 0 }
        return signals[node.id].power
    }

    /// Returns the optical signal at the given node.
    public func signal(at node: OpticalNode) -> OpticalSignal {
        guard node.id > 0, node.id < nodeCount else { return .zero }
        return signals[node.id]
    }

    /// Subscript access by OpticalNode.
    public subscript(node: OpticalNode) -> OpticalSignal {
        get {
            guard node.id > 0, node.id < nodeCount else { return .zero }
            return signals[node.id]
        }
        set {
            guard node.id > 0, node.id < nodeCount else { return }
            signals[node.id] = newValue
        }
    }
}
