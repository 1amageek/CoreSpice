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
    public private(set) var signals: [OpticalSignal]

    /// Sensitivity map: dP_optical / dV_electrical.
    /// Populated during DAG evaluation via forward-mode sensitivity propagation.
    public var sensitivities: OpticalSensitivityMap

    public init(nodeCount: Int = 0) {
        precondition(nodeCount >= 0, "Optical node count must be nonnegative")
        self.nodeCount = nodeCount
        self.signals = [OpticalSignal](repeating: .zero, count: nodeCount)
        self.sensitivities = OpticalSensitivityMap()
    }

    /// Returns the optical power at the given node.
    public func power(at node: OpticalNode) -> Double {
        if node.id == 0 { return 0 }
        precondition(
            node.id > 0 && node.id < nodeCount,
            "Optical node \(node.id) is outside state size \(nodeCount)"
        )
        return signals[node.id].power
    }

    /// Returns the optical signal at the given node.
    public func signal(at node: OpticalNode) -> OpticalSignal {
        if node.id == 0 { return .zero }
        precondition(
            node.id > 0 && node.id < nodeCount,
            "Optical node \(node.id) is outside state size \(nodeCount)"
        )
        return signals[node.id]
    }

    /// Returns the optical power or a structured bounds failure.
    public func checkedPower(at node: OpticalNode) throws -> Double {
        (try checkedSignal(at: node)).power
    }

    /// Returns the optical signal or a structured bounds failure.
    public func checkedSignal(at node: OpticalNode) throws -> OpticalSignal {
        if node.id == 0 { return .zero }
        guard node.id > 0, node.id < nodeCount else {
            throw OpticalStateAccessError.nodeOutOfBounds(
                nodeID: node.id,
                nodeCount: nodeCount
            )
        }
        return signals[node.id]
    }

    /// Updates a non-ground optical node or throws a structured bounds failure.
    public mutating func setSignal(
        _ signal: OpticalSignal,
        at node: OpticalNode
    ) throws {
        guard node.id != 0 else {
            throw OpticalStateAccessError.groundNodeIsImmutable
        }
        guard node.id > 0, node.id < nodeCount else {
            throw OpticalStateAccessError.nodeOutOfBounds(
                nodeID: node.id,
                nodeCount: nodeCount
            )
        }
        signals[node.id] = signal
    }

    /// Subscript access by OpticalNode.
    public subscript(node: OpticalNode) -> OpticalSignal {
        get {
            if node.id == 0 { return .zero }
            precondition(
                node.id > 0 && node.id < nodeCount,
                "Optical node \(node.id) is outside state size \(nodeCount)"
            )
            return signals[node.id]
        }
        set {
            precondition(
                node.id > 0 && node.id < nodeCount,
                "Optical node \(node.id) is immutable or outside state size \(nodeCount)"
            )
            signals[node.id] = newValue
        }
    }
}
