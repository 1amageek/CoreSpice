/// Refusal of an invalid, unbounded or numerically unsupported network observation.
public enum NetworkParameterError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidPort(String)
    case dependentPorts
    case invalidMatrix
    case matrixIndex(row: Int, column: Int)
    case nonFinite(String)
    case residualExceeded(row: Int, value: Double, limit: Double)
    case singularScatteringTransform
    case temporaryStorageExceeded(limit: Int, requested: Int)
    case inconsistentSavedPoint(String)
}
