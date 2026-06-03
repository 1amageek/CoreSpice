import CoreSpiceIR

/// Precomputed waveform variable descriptors for an MNA variable map.
///
/// Simulation runs that share the same topology can reuse this layout when
/// converting results into waveform data, avoiding repeated descriptor sorting
/// and allocation on every conversion.
public struct WaveformVariableLayout: Sendable {
    public let variables: [VariableDescriptor]

    public init(variableMap: [MNAVariable: Int], topology: CircuitTopology) {
        self.variables = Self.buildVariableDescriptors(from: variableMap)
    }

    private static func buildVariableDescriptors(from variableMap: [MNAVariable: Int]) -> [VariableDescriptor] {
        var variables: [VariableDescriptor?] = Array(repeating: nil, count: variableMap.count)
        for (mnaVariable, solverIndex) in variableMap {
            precondition(solverIndex >= 0 && solverIndex < variables.count, "MNA variable index out of range")
            variables[solverIndex] = descriptor(for: mnaVariable, index: solverIndex)
        }
        return variables.map { descriptor in
            guard let descriptor else {
                preconditionFailure("MNA variable indices must be contiguous")
            }
            return descriptor
        }
    }

    private static func descriptor(for variable: MNAVariable, index: Int) -> VariableDescriptor {
        switch variable {
        case .nodeVoltage(let node):
            return VariableDescriptor(
                name: "V(\(node.id))",
                unit: .volt,
                type: .voltage,
                index: index
            )
        case .branchCurrent(let branch):
            return VariableDescriptor(
                name: "I(\(branch.id))",
                unit: .ampere,
                type: .current,
                index: index
            )
        }
    }
}
