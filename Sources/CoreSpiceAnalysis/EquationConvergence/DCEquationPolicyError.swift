/// Invalid explicit DC row policy or its mapping to compiled unknowns.
public enum DCEquationPolicyError: Error, Sendable, Equatable {
    case invalidVariableTolerance(Double)
    case invalidEquationTolerance(Double)
    case dimensionMismatch(expected: Int, actual: Int)
    case invalidVariableMap
    case variableKindMismatch(row: Int)
}
