import CoreSpiceIR

/// Sparse map of optical power sensitivities to electrical variables.
///
/// During DAG evaluation, sensitivities are accumulated using forward-mode:
/// - **Optical emitters** (LD/LED): set `dP_out/dV_anode`, `dP_out/dV_cathode`
/// - **Passive optical devices** (waveguide): multiply input sensitivities by
///   the power transfer coefficient `T`, propagating via chain rule
/// - **Optical receivers** (PD): read accumulated `dP/dV` to stamp `gm_opto`
///   into the MNA Jacobian, ensuring quadratic NR convergence
///
/// Storage is sparse: only nonzero entries are stored as `(opticalNodeId, electricalVarIndex) -> dP/dV`.
public struct OpticalSensitivityMap: Sendable {

    /// Key identifying a sensitivity entry.
    public struct Key: Hashable, Sendable {
        public let opticalNodeId: Int
        public let electricalVarIndex: Int

        public init(opticalNodeId: Int, electricalVarIndex: Int) {
            self.opticalNodeId = opticalNodeId
            self.electricalVarIndex = electricalVarIndex
        }
    }

    private var entries: [Key: Double] = [:]

    public init() {}

    /// Sets the sensitivity dP/dV for the given optical node and electrical variable.
    public mutating func set(opticalNode: Int, electricalVar: Int, value: Double) {
        let key = Key(opticalNodeId: opticalNode, electricalVarIndex: electricalVar)
        if abs(value) > 1e-30 {
            entries[key] = value
        } else {
            entries.removeValue(forKey: key)
        }
    }

    /// Returns the sensitivity dP/dV for the given optical node and electrical variable.
    public func get(opticalNode: Int, electricalVar: Int) -> Double {
        entries[Key(opticalNodeId: opticalNode, electricalVarIndex: electricalVar)] ?? 0
    }

    /// Returns all sensitivity entries for the given optical node.
    public func sensitivities(for opticalNode: Int) -> [(electricalVarIndex: Int, dPdV: Double)] {
        entries.compactMap { key, value in
            key.opticalNodeId == opticalNode ? (key.electricalVarIndex, value) : nil
        }
    }

    /// Propagates sensitivities from an input optical node to an output optical node
    /// by multiplying all entries by a transfer coefficient.
    ///
    /// Used by passive optical devices (waveguides, splitters):
    /// `dP_out/dV = T × dP_in/dV`
    public mutating func propagate(from inputNode: Int, to outputNode: Int, coefficient: Double) {
        let inputEntries = sensitivities(for: inputNode)
        for (elecVar, dPdV) in inputEntries {
            let existing = get(opticalNode: outputNode, electricalVar: elecVar)
            set(opticalNode: outputNode, electricalVar: elecVar, value: existing + coefficient * dPdV)
        }
    }

    /// Removes all entries.
    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Whether there are any sensitivity entries.
    public var isEmpty: Bool { entries.isEmpty }
}
