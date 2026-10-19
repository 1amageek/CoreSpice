/// Invalid or unrepresentable compensated numerical input.
public enum NumericalStateError: Error, Sendable, Equatable {
    case nonFiniteComponent
    case nonNormalizedPair
    case arithmeticOverflow
    case invalidRadius(Double)
    case divisionByZero
    case lowComponentCountMismatch(expected: Int, actual: Int)
    case missingHighHistory
    case incompatiblePrecisionConfiguration
    case unsupportedVoltageLimiter
}
