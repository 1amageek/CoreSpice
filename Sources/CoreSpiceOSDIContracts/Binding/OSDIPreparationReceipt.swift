import OSDIContracts

/// Copied setup facts. Equality compares the complete input and facts, not executable authority.
public struct OSDIPreparationReceipt: Sendable, Equatable {
    public let resolved: OSDIResolvedInstance
    public let effectiveTemperatureKelvin: Double
    public let topology: OSDIPreparedTopology
    public let simulationParameters: [OSDISimulationParameter]
    public let resolvedParameters: [OSDIResolvedParameter]

    public init(resolved: OSDIResolvedInstance, effectiveTemperatureKelvin: Double,
                topology: OSDIPreparedTopology,
                resolvedParameters: [OSDIResolvedParameter],
                simulationParameters: [OSDISimulationParameter] = []) throws(OSDIIntegrationFailure) {
        guard effectiveTemperatureKelvin.isFinite, effectiveTemperatureKelvin > 0 else {
            throw .invalidTemperature
        }
        guard resolved.previousState.count == topology.stateCount else {
            throw .stateDimensionMismatch(expected: topology.stateCount, actual: resolved.previousState.count)
        }
        var modelIndices = Set<Int>()
        var instanceIndices = Set<Int>()
        for fact in resolvedParameters {
            let inserted: Bool
            switch fact.scope {
            case .model: inserted = modelIndices.insert(fact.parameter.index).inserted
            case .instance: inserted = instanceIndices.insert(fact.parameter.index).inserted
            }
            guard inserted else {
                throw .duplicateResolvedParameter(index: fact.parameter.index, scope: fact.scope)
            }
        }
        var simulationNames = Set<String>()
        for parameter in simulationParameters {
            guard simulationNames.insert(parameter.name).inserted else {
                throw .duplicateSimulationParameter(name: parameter.name)
            }
        }
        self.simulationParameters = simulationParameters
        self.resolved = resolved
        self.effectiveTemperatureKelvin = effectiveTemperatureKelvin
        self.topology = topology
        self.resolvedParameters = resolvedParameters
    }
    /// Ordered source bytes and represented real bits are preparation identity.
    public static func simulationParametersEqual(_ lhs: [OSDISimulationParameter],
        _ rhs: [OSDISimulationParameter]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            let a = lhs[index], b = rhs[index]
            guard a.name.utf8.elementsEqual(b.name.utf8) else { return false }
            switch (a.value, b.value) {
            case (.real(let x), .real(let y)):
                guard x.bitPattern == y.bitPattern else { return false }
            case (.string(let x), .string(let y)):
                guard x.utf8.elementsEqual(y.utf8) else { return false }
            default: return false
            }
        }
        return true
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resolved == rhs.resolved && lhs.effectiveTemperatureKelvin == rhs.effectiveTemperatureKelvin
            && lhs.topology == rhs.topology && lhs.resolvedParameters == rhs.resolvedParameters
            && simulationParametersEqual(lhs.simulationParameters, rhs.simulationParameters)
    }

}
