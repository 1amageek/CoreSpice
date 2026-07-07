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

    public init(validatingVariableMap variableMap: [MNAVariable: Int], topology: CircuitTopology) throws {
        self.variables = try Self.buildValidatedVariableDescriptors(from: variableMap, topology: topology)
    }

    private static func buildVariableDescriptors(
        from variableMap: [MNAVariable: Int],
        topology: CircuitTopology
    ) -> [VariableDescriptor] {
        do {
            return try buildDescriptors(from: variableMap, topology: topology, strict: false)
        } catch {
            return []
        }
    }

    private static func buildValidatedVariableDescriptors(
        from variableMap: [MNAVariable: Int],
        topology: CircuitTopology
    ) throws -> [VariableDescriptor] {
        try buildDescriptors(from: variableMap, topology: topology, strict: true)
    }

    private static func buildDescriptors(
        from variableMap: [MNAVariable: Int],
        topology: CircuitTopology,
        strict: Bool
    ) throws -> [VariableDescriptor] {
        var variables: [VariableDescriptor?] = Array(repeating: nil, count: variableMap.count)
        for (mnaVariable, solverIndex) in variableMap {
            guard solverIndex >= 0 && solverIndex < variables.count else {
                if strict {
                    throw WaveformValidationError.mnaVariableIndexOutOfRange(
                        index: solverIndex,
                        variableCount: variables.count
                    )
                }
                continue
            }
            variables[solverIndex] = descriptor(for: mnaVariable, topology: topology, index: solverIndex)
        }

        var descriptors: [VariableDescriptor] = []
        descriptors.reserveCapacity(variables.count)
        for (index, descriptor) in variables.enumerated() {
            guard let descriptor else {
                if strict {
                    throw WaveformValidationError.mnaVariableIndicesNotContiguous(missingIndex: index)
                }
                continue
            }
            descriptors.append(descriptor)
        }
        return descriptors
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
