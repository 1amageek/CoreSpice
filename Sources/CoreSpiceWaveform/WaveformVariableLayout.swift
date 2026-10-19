import CoreSpiceIR

/// Precomputed waveform variable descriptors for an MNA variable map.
///
/// Simulation runs that share the same topology can reuse this layout when
/// converting results into waveform data, avoiding repeated descriptor sorting
/// and allocation on every conversion.
public struct WaveformVariableLayout: Sendable {
    public let variables: [VariableDescriptor]
    private let variableMap: [MNAVariable: Int]

    public init(variableMap: [MNAVariable: Int], topology: CircuitTopology) {
        self.variables = Self.buildVariableDescriptors(from: variableMap, topology: topology)
        self.variableMap = variableMap
    }

    /// Creates a checked layout, marking explicit thermal unknowns as temperature rises in kelvins.
    ///
    /// Thermal identities must exist in the compiled map; ground cannot be a temperature-rise unknown.
    public init(
        validatingVariableMap variableMap: [MNAVariable: Int],
        topology: CircuitTopology,
        temperatureRiseNodes: Set<Node> = []
    ) throws {
        for node in temperatureRiseNodes {
            guard node != .ground, variableMap[.nodeVoltage(node)] != nil else {
                throw WaveformValidationError.unknownTemperatureRiseNode(nodeID: node.id)
            }
        }
        self.variables = try Self.buildDescriptors(
            from: variableMap,
            topology: topology,
            strict: true,
            temperatureRiseNodes: temperatureRiseNodes
        )
        self.variableMap = variableMap
    }

    func validate(variableMap: [MNAVariable: Int], variableCount: Int) throws {
        guard self.variableMap == variableMap else {
            throw WaveformValidationError.variableLayoutMapMismatch
        }
        guard variables.count == variableCount else {
            throw WaveformValidationError.variableLayoutWidthMismatch(
                expected: variableCount,
                actual: variables.count
            )
        }
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

    private static func buildDescriptors(
        from variableMap: [MNAVariable: Int],
        topology: CircuitTopology,
        strict: Bool,
        temperatureRiseNodes: Set<Node> = []
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
            variables[solverIndex] = descriptor(
                for: mnaVariable,
                topology: topology,
                index: solverIndex,
                temperatureRiseNodes: temperatureRiseNodes
            )
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
        index: Int,
        temperatureRiseNodes: Set<Node>
    ) -> VariableDescriptor {
        switch variable {
        case .nodeVoltage(let node):
            let isTemperatureRise = temperatureRiseNodes.contains(node)
            return VariableDescriptor(
                name: "\(isTemperatureRise ? "dT" : "V")(\(topology.name(for: node) ?? String(node.id)))",
                unit: isTemperatureRise ? .kelvin : .volt,
                type: isTemperatureRise ? .temperature : .voltage,
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
