import CoreSpiceIR

/// Precomputed waveform variable descriptors for an MNA variable map.
///
/// Simulation runs that share the same topology can reuse this layout when
/// converting results into waveform data, avoiding repeated descriptor sorting
/// and allocation on every conversion.
public struct WaveformVariableLayout: Sendable {
    public let variables: [VariableDescriptor]

    public init(variableMap: [MNAVariable: Int], topology: CircuitTopology) {
        self.variables = Self.buildVariableDescriptors(from: variableMap, topology: topology)
    }

    private static func buildVariableDescriptors(
        from variableMap: [MNAVariable: Int],
        topology: CircuitTopology
    ) -> [VariableDescriptor] {
        var variables: [VariableDescriptor?] = Array(repeating: nil, count: variableMap.count)
        for (mnaVariable, solverIndex) in variableMap {
            precondition(solverIndex >= 0 && solverIndex < variables.count, "MNA variable index out of range")
            variables[solverIndex] = descriptor(for: mnaVariable, topology: topology, index: solverIndex)
        }
        return variables.map { descriptor in
            guard let descriptor else {
                preconditionFailure("MNA variable indices must be contiguous")
            }
            return descriptor
        }
    }

    private static func descriptor(
        for variable: MNAVariable,
        topology: CircuitTopology,
        index: Int
    ) -> VariableDescriptor {
        switch variable {
        case .nodeVoltage(let node):
            return VariableDescriptor(
                name: "V(\(topology.name(for: node) ?? String(node.id)))",
                unit: .volt,
                type: .voltage,
                index: index
            )
        case .branchCurrent(let branch):
            return VariableDescriptor(
                name: "I(\(topology.name(for: branch) ?? String(branch.id)))",
                unit: .ampere,
                type: .current,
                index: index
            )
        }
    }
}
