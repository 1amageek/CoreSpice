import OSDIContracts

/// Copied setup facts. Equality compares the complete input and facts, not executable authority.
public struct OSDIPreparationReceipt: Sendable, Equatable {
    public let resolved: OSDIResolvedInstance
    public let effectiveTemperatureKelvin: Double
    public let topology: OSDIPreparedTopology
    public let resolvedParameters: [OSDIResolvedParameter]

    public init(resolved: OSDIResolvedInstance, effectiveTemperatureKelvin: Double,
                topology: OSDIPreparedTopology,
                resolvedParameters: [OSDIResolvedParameter]) throws(OSDIIntegrationFailure) {
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
        self.resolved = resolved
        self.effectiveTemperatureKelvin = effectiveTemperatureKelvin
        self.topology = topology
        self.resolvedParameters = resolvedParameters
    }
}
