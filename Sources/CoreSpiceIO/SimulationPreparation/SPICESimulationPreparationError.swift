public enum SPICESimulationPreparationError: Error, Sendable {
    case invalidPolicy
    case missingAnalysis
    case unsupportedCapability(String)
    case invalidSupplyBinding(String)
    case missingConditionCoverage
    case conditionMismatch
    case resource(any Error)
    case source(any Error)
    case parser(any Error)
    case lowering(any Error)
    case options(any Error)
    case nodeVoltage(SPICENodeVoltageResolutionError)
}
