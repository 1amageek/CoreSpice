public enum AnalysisResultValidationError: Error, Sendable, Equatable {
    case negativeCount(field: String, value: Int)
    case countMismatch(field: String, expected: Int, actual: Int)
    case nonFiniteValue(field: String, index: Int, value: Double)
    case negativeValue(field: String, index: Int, value: Double)
    case nonIncreasingValue(field: String, index: Int, previous: Double, value: Double)
    case invalidVariableIndex(index: Int, variableCount: Int)
    case duplicateVariableIndex(Int)
    case emptyOutputVariable
    case nonFiniteComplex(field: String, index: Int)
    case variableMapMismatch
}
