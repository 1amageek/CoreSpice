/// Caller-owned absolute tolerances in the units selected by `kind`.
public struct DCEquationRowPolicy: Sendable {
    public let kind: DCEquationKind
    public let variableAbsoluteTolerance: Double
    public let equationAbsoluteTolerance: Double

    public init(
        kind: DCEquationKind,
        variableAbsoluteTolerance: Double,
        equationAbsoluteTolerance: Double
    ) throws {
        guard variableAbsoluteTolerance.isFinite, variableAbsoluteTolerance > 0 else {
            throw DCEquationPolicyError.invalidVariableTolerance(variableAbsoluteTolerance)
        }
        guard equationAbsoluteTolerance.isFinite, equationAbsoluteTolerance > 0 else {
            throw DCEquationPolicyError.invalidEquationTolerance(equationAbsoluteTolerance)
        }
        self.kind = kind
        self.variableAbsoluteTolerance = variableAbsoluteTolerance
        self.equationAbsoluteTolerance = equationAbsoluteTolerance
    }
}
